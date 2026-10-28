# Implementation notes

How the parser works under the hood and how it is validated. For usage, see
the [README](README.md); for contribution conventions, [AGENTS.md](AGENTS.md).

## Streaming design

The diff is parsed as a **byte stream**: callers feed chunks to a parser
(the tests read 4 MiB at a time), so the diff never has to fit in memory.
Chunks may split lines — or multi-byte UTF-8 characters — anywhere; results
are byte-for-byte identical for any chunking (tested down to 1-byte chunks).
Splitting happens on the `\n` byte, which is unambiguous in UTF-8.

Hot paths operate on `ArraySlice<UInt8>`; `String` is only reached after a
cheap byte-level prefix check. Hunk headers are parsed with a hand-rolled
digit scanner that stops at 2⁴⁸, far above any real line number and far
below overflow, so corrupt input rejects the header instead of trapping.

### Events, then collectors

Parsing is layered (see [docs/diff-model.md](docs/diff-model.md)):

- `DiffEventParser<Consumer>` splits lines, reads headers and hunks, and
  calls a `DiffEventConsumer`'s `mutating` methods: `beginFile`,
  `beginHunk`, `line`, `noNewlineAtEndOfFile`, `binaryPatchLine`, `endFile`,
  `unrecognizedLine`, `damage`, and, last, `noNewlineAtEndOfInput`. Line content arrives as a `Span<UInt8>`
  into the parser's buffers, valid only during the call, so the event layer
  allocates nothing per line. The consumer is a generic parameter, so the
  calls specialize and inline.
- Collectors are consumers that keep what they need, from least to most:
  - `ChangedLines.Collector` records added lines per file; `DiffParser` is
    a thin facade over it, kept for 0.1's API.
  - `DiffSummary.Collector` keeps each file's `FileHeader` and its added
    and deleted line counts. Its memory grows with the file count, not the
    content.
  - `Diff.Collector` keeps everything: the full model, `Diff`, whose
    memory grows with the diff's content (about 2.5× its size). Its entry
    points raise the line cap to 64 MiB (`ParsingOptions.fullModel`).
  The summary and the full model keep every damage report in input order.

The full model stores each file packed rather than one allocation per line
(design doc D8). Hunk line content goes back to back into one byte arena
per file, so a line is a 32-byte record — old and new number, the offset
where its content ends (it starts where the previous line's ends), and a
two bytes of flags — and everything else (raw header, headings, binary
patch lines, unrecognized lines) into a second arena, with records of
offsets.
Offsets are `Int`, so there is no per-file size limit to police. The
public collections (`DiffFile.Hunks`, `Lines`, `TextLines`) build their
elements on access, with content as slices of the arenas, so an element
can't be read against the wrong file's storage. Unrecognized lines keep
their position: before the first file in `Diff.preamble`, inside a file
before its first hunk (`leadingLines`) or after the hunk they follow
(`trailingLines`).

`Diff.render(_:)` writes the model back as unified diff text, in 64 KiB
chunks handed to a closure, and `[UInt8](rendering:)` builds it whole. For
git's output the text is the input byte for byte, because every byte lands
somewhere: raw header blocks verbatim, unrecognized lines at their
positions, hunk headers with their implicit counts, and the `\r` of every
line as a flag — content, hunk header, and no-newline marker alike — plus
context lines written without their space (`diff.suppressBlankEmpty`) and
whether the input's last line ended in `\n`. A file renders from its raw
header, never from its `FileHeader`. Each flush keeps the buffer's last
byte back, so a final newline the input lacked can still be dropped,
however the chunks fell. What the model doesn't keep can't come back:
combined diffs' hunks, damaged files, bytes past the line cap, a
localized no-newline marker's wording, and leading zeros in hunk numbers.

The parser's working memory is bounded whatever the input: the line carry
buffer by the line cap (`ParsingOptions.maximumLineLength`), and the raw
header block — kept verbatim for `beginFile`'s `rawHeader` — by 64 lines
and 1 MiB. A header over either bound abandons its file.

Damage never throws or traps. The parser repairs locally (a hunk cut short,
a line without a marker, a header value that doesn't parse) or abandons the
file (`headerTooLarge`, `tooManyParents`) and reports it as a `damage`
event with a severity, the input line number, and the file's header as far
as it was read. While a file is abandoned, further reports for it are
suppressed. The library never logs; tools decide what to show.

Combined diffs (`diff --cc`/`--combined`) are recognized and skipped: each
file gets `beginFile` with format `.combined(parents:)` and `endFile`, while
its hunks are only counted, against one budget per parent, so their content
can't be mistaken for headers or another file's lines. An abandoned combined
file (too many parents, or a header over its bounds) can't be counted, so
everything up to the next `diff ` line is dropped instead.

Plain `diff -N` output marks a missing file with a Unix-epoch timestamp;
as `git apply` does, an epoch on the old side makes the file an addition
and on the new side a deletion, in any zone, but only when the zone is
written out (GNU diff writes it; Apple's diff doesn't, and git doesn't read
those either).

Coloured output (`--color`, `color.ui=always`) isn't read. An SGR escape
code starts every header line, so none passes the byte-level gate, no file
begins, and every line is unrecognized: the full model keeps them all in
`Diff.preamble`, and nothing is reported as damage, since nothing was cut
short. Whether to strip the codes or report such input is undecided; the
entry points' documentation says to pass `--no-color`.

Changed lines are stored as sorted, merged ranges (`LineRangeSet`) rather
than per-line sets, so memory scales with the number of *edits*, not lines:
a full-file rewrite is a single range. Membership tests are binary searches,
with tolerance comparisons ordered so extreme values cannot overflow.

The library itself doesn't import Foundation. One Foundation trap worth
knowing when a caller feeds it from a file on Darwin: `FileHandle.read`
returns autoreleased `Data`, so wrap each read iteration in `autoreleasepool`
— without it the chunks accumulate until process exit and streaming silently
degrades to whole-file memory. Linux has no autorelease pool and no such
trap.

Individual lines are processed truncated to the line cap, 1 MiB by default
(uniformly, so results stay chunking-independent), and flagged
`isTruncated`. This caps the carry buffer a pathological newline-free input
could otherwise grow without limit. A `\r` before the `\n` is stripped and
flagged per line, the same for any chunking, so CRLF diffs parse like LF
ones; a last line without `\n` is flagged by `noNewlineAtEndOfInput`.

## Performance

Measured on real-world input (Apple Silicon, release build) — the Linux
kernel v6.6 → v6.7 release diff, one of the largest diffs in open source,
plus a 6× concatenation of it. Numbers come from the `changes` command of
[swift-steward](https://github.com/marosoaie/swift-steward)'s CLI, a thin
wrapper that reads the file in 4 MiB chunks and prints JSON:

| Input | Size | Time | Peak RSS |
|---|---|---|---|
| kernel 6.6→6.7 diff (12,057 files, 906k added lines) | 70 MB | 0.2 s | 67 MB |
| 6× concatenated kernel diff | 422 MB | 0.7 s | 67 MB |
| same, piped through stdin | 422 MB | 0.7 s | 67 MB |

Peak memory is flat from 70 MB to 422 MB of input — the residual is the
result itself (12k paths, ~250k ranges), not the diff. Measurements use
`/usr/bin/time -l` on release builds; performance-relevant changes are
re-benchmarked on these fixtures before merging (see AGENTS.md).

The collectors compared, on the library alone (a release harness reading
4 MiB chunks, without the CLI's JSON; Apple M4, Swift 6.4, step 2.5):

| Collector | kernel diff (74 MB, 13,479 files) | 6× kernel diff (443 MB) |
|---|---|---|
| `ChangedLines` | 0.11 s, 22 MB | 0.56 s, 19 MB |
| `DiffSummary` | 0.13 s, 24 MB | 0.76 s, 59 MB |
| `Diff` (full model) | 0.20 s, 187 MB | 1.25 s, 1.1 GB |

`ChangedLines` stays flat; the summary grows with the file count (about
500 bytes per file: its header, two paths, and array slack); the full
model grows with the content, peaking at about 2.5× the diff.

Rendering the kernel diff's model back (same harness, step 2.6) takes
about 90 ms on top of the parse, and streaming it costs no memory beyond
the model's: parse and `render(_:)` to standard output run in 0.29 s and
peak at 188 MB. `[UInt8](rendering:)` holds the whole text as well, with
its array's growth slack: 0.39 s, 381 MB.

## Validation against real-world diffs

`swift test` runs two kinds of suites:

- **Unit and fixture tests** — parser edge cases (renames, quoted paths,
  CRLF, chunk boundaries, diff-syntax-lookalike content, malformed and
  hostile input) plus a committed real PR diff (swiftlang/swift #70000) with
  independently verified expectations.
- **Real-world large-diff tests** — parse the Linux kernel v6.6→v6.7 release
  patch (~70 MB), GitHub's redis 7.0→7.2 compare diff (renames), and
  swift-argument-parser's 1.0→1.5 compare diff, then cross-check every
  per-file changed-line count against git's own patch parser
  (`git apply --numstat`) as an independent oracle; the summary's headers
  and both counts against `git apply --summary` and `--numstat -z`; the
  full model's counts against `--numstat -z` and its contents against the
  event stream; and the full model renders each diff back to its input,
  byte for byte. Fixtures are downloaded
  from their canonical URLs and cached in
  `~/Library/Caches/git-diff-parser-tests/` (on Linux,
  `$XDG_CACHE_HOME/git-diff-parser-tests/`, falling back to `~/.cache`);
  cache entries are re-validated
  before use. Nothing large is committed to the repo — keeping the clone
  free of Git LFS matters because SwiftPM consumers clone it on machines
  that may have broken or absent `git-lfs` setups.

- **The git oracle repository** — two commits built with
  `git fast-import`, so paths can hold any bytes, holding every kind of
  change the headers describe (creations, deletions, renames, copies,
  rewrites, mode changes, symlinks, a gitlink, binary files) and every
  line ending (CRLF content, missing final newlines, empty context
  lines). Each of several `git diff` variants is checked against
  `git apply --summary` and `--numstat -z`, against `git ls-tree` for
  every path, mode, and object ID, and for the round trip: the rendering
  is git's diff byte for byte, and with `--binary`, `git apply --cached`
  of it turns the old tree into exactly the new one. `git show`,
  `git log -p`, and `git format-patch` output render back too.

Set `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS=1` to skip the real-world suite
(e.g. in offline environments). Tests pass under both `swift test` and
Xcode/`xcodebuild test`, whose build-product layouts differ.

## Concurrency and safety posture

Every target builds with Swift 6.2 strict concurrency plus
`ExistentialAny`, `MemberImportVisibility`, `InferIsolatedConformances`,
`NonisolatedNonsendingByDefault`, and `strictMemorySafety()`; the build is
kept warning-free. Model types are `Sendable`. The library never throws on
malformed input — damage stays contained to the malformed file (truncated
hunks recover at the next file header).
