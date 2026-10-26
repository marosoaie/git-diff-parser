# Changelog

Every notable change to GitDiffKit. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [semantic versioning](https://semver.org/spec/v2.0.0.html): until
1.0, a minor version may break the API.

## Unreleased

GitDiffKit grows from changed-line ranges into a layered diff model: a
streaming event parser at the bottom, with three collectors on top —
`ChangedLines`, a per-file `DiffSummary`, and the full `Diff`, which
renders back to its input. It now builds on Linux and every Apple
platform.

### Breaking changes

- **Platforms.** On Apple platforms, GitDiffKit needs the 26 releases
  (macOS, iOS, tvOS, watchOS, and visionOS 26), whose standard library
  has `Span`; 0.1.0 needed macOS 14. Linux, newly supported, has no
  floor.
- **`DiffParser.consume(_: Data)` is removed**, since the library no
  longer imports Foundation. Pass `[UInt8](data)` instead.

### Added

- **Linux support**, tested in CI on Ubuntu with the `swift:6.2` image,
  and support for iOS, tvOS, watchOS, and visionOS.
- **The event layer.** `DiffEventParser<Consumer>` streams a diff in
  chunks of any size and calls a `DiffEventConsumer`'s `mutating`
  methods: `beginFile`, `beginHunk`, `line`, `noNewlineAtEndOfFile`,
  `binaryPatchLine`, `endFile`, `unrecognizedLine`, `damage`, and
  `noNewlineAtEndOfInput`. Every method has an empty default. Line
  content arrives as a `Span<UInt8>` into the parser's buffers;
  `[UInt8](copying:)` and `String(decodingLossily:)` copy it out.
- **File headers.** `FileHeader` reads git's extended headers: the
  file's `Change` (added, deleted, modified, renamed or copied with
  their similarity), old and new `DiffPath`s (exact bytes, quoting
  undone), `FileMode`s and `modeChanged`, `ObjectID`s (SHA-1 or
  SHA-256, abbreviated or full), a rewrite's dissimilarity, whether the
  file is binary, and its `Format`: git, combined, or plain unified.
  `HunkHeader` and `LineInfo` describe hunks and lines, with flags for
  a line's `\r`, truncation, and a missing marker column.
- **`DiffSummary`**: each file's header with its added and deleted line
  counts, what `git apply --summary` and `--numstat` report, with
  memory that grows with the file count only.
- **`Diff`, the full model**: every file's raw header, hunks
  (`DiffHunk`), lines with their content (`DiffLine`), binary patch
  lines, and the unrecognized lines around them (`DiffTextLine`), plus
  the text before the first file. Its memory grows with the diff's
  content, about 2.5× its size.
- **Rendering.** `Diff.render(_:)` writes the full model back as unified
  diff text in chunks, and `[UInt8](rendering:)` builds it whole; for
  git's output, the text is the input byte for byte.
- **Damage reports.** Damaged input produces a `DamageReport` event with
  its reason, input line, file, and severity: `info` for a local
  recovery, `error` for an abandoned file. `DiffSummary` and `Diff`
  keep every report.
- **`ParsingOptions`**, whose `maximumLineLength` sets the line cap
  (1 MiB by default). The full model's entry points, `Diff(diff:)` and
  `DiffEventParser<Diff.Collector>()`, raise it to 64 MiB
  (`ParsingOptions.fullModel`).
- **`ChangedLines.Collector`**, the consumer behind `DiffParser`, for
  use with `DiffEventParser`.
- **Documentation**: a DocC catalog with articles on getting started,
  choosing a collector, streaming, and damaged input, whose samples are
  compiled and run by the tests; this changelog, CONTRIBUTING.md, and
  SECURITY.md.

### Changed

- `ChangedLines` and `DiffParser` are built on the event layer. On git's
  own output their results are unchanged, which was checked on the Linux
  kernel, redis, and swift-argument-parser diffs.
- **Combined diffs of merges** (`diff --cc`, `diff --combined`) are
  recognized and skipped: they add no lines to `ChangedLines`, and their
  content can no longer be mistaken for file headers. For the lines a
  merge changed, diff it against its first parent
  (`--diff-merges=first-parent`).
- **Plain diffs** (`diff -uN`, `diff -ruN`): a Unix-epoch timestamp
  marks the file created or deleted, as `git apply` reads it.
- **Bounded headers.** A file's header block over 64 lines or 1 MiB
  abandons the file instead of growing a buffer without limit.
- Damaged input that git never writes is read the way `git apply` reads
  it:
  - a lone `+++` line no longer starts a file;
  - an unusable `+++` path falls back to the name on the `diff --git`
    line, and hunks under a `diff --git` line with no `+++` line are
    recorded under that name;
  - a `Binary files … differ` line outside a header no longer resets
    the current path;
  - an abandoned file's lines are dropped;
  - a file whose epoch timestamp deletes it records no lines, even if
    it adds some.
- `ChangedLines` documents that its `String` keys compare by Unicode
  canonical equivalence: the NFC and NFD spellings of one name, which
  git treats as two paths, share a key.

## 0.1.0 — 2026-10-23

The first release: `DiffParser` and `ChangedLines(diff:)` stream a
unified diff into the new-side line numbers each file adds, stored as
merged ranges (`LineRangeSet`), on macOS 14 and later.
