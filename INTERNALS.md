# Implementation notes

How git-diff-parser works under the hood and how it is validated. For usage,
see the [README](README.md); for contribution conventions, [AGENTS.md](AGENTS.md).

## Streaming design

Both inputs are parsed as **byte streams**: the CLI reads 4 MiB chunks and
feeds them to incremental parsers (`DiffParser`, the `LogParsing`
conformers), so neither the diff nor the log ever has to fit in memory.
Chunks may split lines — or multi-byte UTF-8 characters — anywhere; results
are byte-for-byte identical for any chunking (tested down to 1-byte chunks).
Splitting happens on the `\n` byte, which is unambiguous in UTF-8.

Hot paths operate on `ArraySlice<UInt8>`; `String` and `Regex` are only
reached after a cheap byte-level gate (log lines are pre-filtered for a
severity marker before the diagnostic regex runs). Hunk headers are parsed
with a hand-rolled digit scanner using overflow-checked arithmetic, so
corrupt input rejects the header instead of trapping.

Changed lines are stored as sorted, merged ranges (`LineRangeSet`) rather
than per-line sets, so memory scales with the number of *edits*, not lines:
a full-file rewrite is a single range. Membership tests are binary searches,
with tolerance comparisons ordered so extreme values cannot overflow.

One Foundation trap worth knowing: `FileHandle.read` returns autoreleased
`Data`, so the CLI wraps each read iteration in `autoreleasepool` — without
it the chunks accumulate until process exit and streaming silently degrades
to whole-file memory.

## Performance

Measured on real-world input (Apple Silicon, release build) — the Linux
kernel v6.6 → v6.7 release diff, one of the largest diffs in open source,
plus a 6× concatenation of it:

| Input | Size | Time | Peak RSS |
|---|---|---|---|
| `changes`, kernel 6.6→6.7 diff (12,057 files, 906k added lines) | 70 MB | 0.2 s | 67 MB |
| `changes`, 6× concatenated kernel diff | 422 MB | 0.7 s | 67 MB |
| same, piped through stdin | 422 MB | 0.7 s | 67 MB |
| `filter`, 1.9M-line build log against the kernel diff | 94 MB + 70 MB | 2.4 s | 24 MB |

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
  (`git apply --numstat`) as an independent oracle. The kernel and redis
  diffs are committed as xz-compressed **Git LFS** fixtures; the
  swift-argument-parser diff is always downloaded, so the network path stays
  exercised. Downloads are cached in
  `~/Library/Caches/git-diff-parser-tests/`, cache entries are re-validated
  before use, and a clone without `git lfs` falls back to downloading
  automatically.

Set `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS=1` to skip the real-world suite
(e.g. in offline environments). Tests pass under both `swift test` and
Xcode/`xcodebuild test`, whose build-product layouts differ.

## Concurrency and safety posture

Every target builds with Swift 6.2 strict concurrency plus
`ExistentialAny`, `MemberImportVisibility`, `InferIsolatedConformances`,
`NonisolatedNonsendingByDefault`, and `strictMemorySafety()`; the build is
kept warning-free. Model types are `Sendable`; parser types that hold a
`Regex` deliberately are not. Libraries never throw on malformed input —
damage stays contained to the malformed file (truncated hunks recover at the
next file header). Only the CLI throws.
