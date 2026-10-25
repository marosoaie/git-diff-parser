# git-diff-parser

A streaming, zero-dependency Swift parser for unified git diffs: which files
does a diff touch, and on which lines?

> **Status: pre-release (0.x).** The API is growing from changed-line ranges
> into a full diff model (file status, renames, hunks, line content), so
> expect breaking changes before 1.0.

- **Streaming.** Feed chunks of any size, split anywhere — even inside a
  multi-byte UTF-8 character. Results are byte-for-byte identical for any
  chunking, and memory scales with the number of edits, not the size of the
  diff: the 70 MB Linux 6.6→6.7 release diff parses in ~0.2 s with flat
  memory.
- **Safe on hostile input.** Malformed, truncated, or adversarial diffs
  never trap: arithmetic is overflow-checked, damage stays contained to the
  broken file, and the parser picks up again at the next file header.
- **Validated against git itself.** Per-file results are cross-checked
  against `git apply --numstat` on the Linux kernel, redis, and
  swift-argument-parser diffs.
- **Swift 6.2 strict concurrency**, `Sendable` model types, no
  dependencies.

## Installation

```swift
// Package.swift
.package(url: "https://github.com/marosoaie/git-diff-parser.git", from: "0.1.0"),
// target dependency:
.product(name: "GitDiffKit", package: "git-diff-parser"),
```

Requires Swift 6.2+. Pure Swift with no Foundation import, so it builds on
every Apple platform and on Linux; CI tests macOS and Ubuntu.

## Usage

```swift
import GitDiffKit

// Whole diff in memory:
let changes = ChangedLines(diff: diffText)

// Or stream it — [UInt8], ArraySlice<UInt8>, or String chunks:
var parser = DiffParser()
while let chunk = nextChunk() { parser.consume(chunk) }
let streamed = parser.finalize()                         // == changes

changes.sortedPaths                                      // ["Sources/App/Foo.swift", …]
changes.ranges(in: "Sources/App/Foo.swift")              // [11...12, 40...40]
changes.contains(line: 42, in: "Sources/App/Foo.swift")  // binary search
changes.contains(line: 42, in: "Sources/App/Foo.swift", tolerance: 2)
```

For anything beyond changed lines, implement a `DiffEventConsumer` — every
method has a default, so take only the events you need — and drive it with
a `DiffEventParser`:

```swift
struct DamageLog: DiffEventConsumer {
    var reports: [DamageReport] = []
    mutating func damage(_ report: DamageReport) { reports.append(report) }
}

var events = DiffEventParser(consumer: DamageLog())
events.consume(diffBytes)
let reports = events.finalize().reports   // where the input was damaged
```

Get a pull request's own changes with a three-dot diff against the merge
base (`git diff origin/main...HEAD`), or download it from GitHub
(`https://github.com/OWNER/REPO/pull/N.diff`).

## Semantics

- Line numbers are **new-side** (post-change) numbers — the ones build logs
  and GitHub's PR view use.
- Only added lines are recorded; git represents a modified line as a removal
  plus an addition, so additions cover both. Deleted lines can't carry
  diagnostics and are ignored.
- Deleted and binary files never appear; renamed files appear under their new
  path, and only if they contain edits.
- Paths are repo-relative. git's C-style quoting is undone, and `a/`/`b/`
  (or mnemonic `c/i/o/w`) prefixes are stripped — but a genuine single-letter
  directory in `--no-prefix` output is kept.
- CRLF diffs parse identically to LF. Lines longer than 1 MiB are processed
  truncated, so pathological input can't grow memory without bound.

## Documentation

- [INTERNALS.md](INTERNALS.md) — streaming design, benchmarks, and how the
  parser is validated.
- [AGENTS.md](AGENTS.md) — contribution conventions and coding style, for
  humans and coding agents alike.

Build/lint tooling built on this library — filtering diagnostics to the
lines a PR touches — lives in
[swift-steward](https://github.com/marosoaie/swift-steward).

## License

[MIT](LICENSE).
