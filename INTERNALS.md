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
  `unrecognizedLine`, and `damage`. Line content arrives as a `Span<UInt8>`
  into the parser's buffers, valid only during the call, so the event layer
  allocates nothing per line. The consumer is a generic parameter, so the
  calls specialize and inline.
- Collectors are consumers that keep what they need. `ChangedLines.Collector`
  records added lines per file; `DiffParser` is a thin facade over it, kept
  for 0.1's API.

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
can't be mistaken for headers or another file's lines.

Plain `diff -N` output marks a missing file with a Unix-epoch timestamp;
as `git apply` does, an epoch on the old side makes the file an addition
and on the new side a deletion, in any zone, but only when the zone is
written out (GNU diff writes it; Apple's diff doesn't, and git doesn't read
those either).

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
ones.

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
  (`git apply --numstat`) as an independent oracle. Fixtures are downloaded
  from their canonical URLs and cached in
  `~/Library/Caches/git-diff-parser-tests/` (on Linux,
  `$XDG_CACHE_HOME/git-diff-parser-tests/`, falling back to `~/.cache`);
  cache entries are re-validated
  before use. Nothing large is committed to the repo — keeping the clone
  free of Git LFS matters because SwiftPM consumers clone it on machines
  that may have broken or absent `git-lfs` setups.

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
