# git-diff-parser

[![CI](https://github.com/marosoaie/git-diff-parser/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/marosoaie/git-diff-parser/actions/workflows/ci.yml)

**GitDiffKit** is a Swift library that reads unified git diffs — the
output of `git diff`, `git show`, `git log -p`, `git format-patch`, a
pull request's `.diff`, or plain `diff -u` — and tells you what they
change: which lines each file adds, what happened to each file, or the
whole diff with every line's content.

It streams: the parser's own memory stays bounded however large the
diff, and what the result keeps is up to the collector you pick. It has no
dependencies and doesn't import Foundation, so it runs on every Apple
platform and on Linux. And it never crashes on a damaged diff: it
repairs what it can, skips what it can't, and tells you which.

> **Pre-release (0.x).** The API can still change between minor
> versions until 1.0; [CHANGELOG.md](CHANGELOG.md) lists every change.

## Quick start

Add the package to your `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReviewBot",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/marosoaie/git-diff-parser.git", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "ReviewBot",
            dependencies: [.product(name: "GitDiffKit", package: "git-diff-parser")]
        ),
    ]
)
```

Then parse a diff, such as the output of `git diff origin/main...HEAD`,
and ask about its lines:

```swift
import GitDiffKit

let changes = ChangedLines(diff: diffText)
let paths = changes.sortedPaths   // ["README.md", "Sources/App/Greeting.swift"]
let greeting = changes.ranges(in: "Sources/App/Greeting.swift")   // [2...3]
let isChanged = changes.contains(line: 3, in: "Sources/App/Greeting.swift")   // true
```

The values in the comments are for the small diff in
[Getting Started](Sources/GitDiffKit/GitDiffKit.docc/GettingStarted.md),
which edits `Greeting.swift`, adds a line to `README.md`, and deletes
another file. Line numbers are new-side numbers, the ones in build logs
and in GitHub's pull request view, so `contains(line:in:)` tells a
linter whether a warning is on a line the change touched.

## Three collectors

Keep only as much of the diff as your question needs:

| Collector | Keeps | Memory grows with | Kernel diff (74 MB) |
|---|---|---|---|
| `ChangedLines` | Each file's added lines, as ranges | The number of edits | 0.11 s, 22 MB |
| `DiffSummary` | Each file's status (added, deleted, renamed, copied, mode change, binary), paths, and line counts | The number of files | 0.13 s, 24 MB |
| `Diff` | Everything: hunks and every line's content; renders git's output back byte for byte, merges aside | The diff's content, about 2.5× its size | 0.20 s, 187 MB |

Times and peak memory are for the Linux 6.6→6.7 release diff (13,479
files), read in 4 MiB chunks by a release build on an Apple M4.

```swift
let summary = DiffSummary(diff: diffText)
summary.files.forEach { file in
    let path = file.header.newPath ?? file.header.oldPath
    print(file.header.change, path?.string ?? "?", file.addedLineCount, file.deletedLineCount)
}
// modified Sources/App/Greeting.swift 2 1
// modified README.md 1 0
// deleted Sources/App/Legacy.swift 0 2
```

Each collector streams: feed a `DiffEventParser` chunks of any size,
split anywhere, and get the same result as from the whole text:

```swift
var parser = DiffEventParser(consumer: DiffSummary.Collector())
while let chunk = readSomeBytes() {
    parser.consume(chunk)
}
let summary = parser.finalize().summary
```

For anything else, implement a `DiffEventConsumer` — every method has a
default, so it takes only the events it needs.

## What it reads

- `git diff` with every extended header: creations, deletions, renames
  and copies with their similarity, mode changes, rewrites, binary files
  (`GIT binary patch` kept, not decoded), and object IDs, SHA-1 or
  SHA-256.
- Paths with any bytes: git's quoting is undone, and the summary and the
  full model keep each path as the exact bytes git wrote.
- `git show`, `git log -p`, and `git format-patch` streams, whose commit
  messages and mail headers the full model keeps in place.
- Plain `diff -u` and `diff -ruN`, including GNU diff's epoch timestamps,
  which mark a created or deleted file.
- CRLF line endings and missing final newlines, recorded per line.
- Merge commits' combined diffs (`diff --cc`) are recognized and skipped:
  they contribute no lines. Diff a merge against its first parent
  (`--diff-merges=first-parent`) to see its changes.
- Not coloured output (`--color`, `color.ui=always`): an escape code
  starts every header line, so it reads as no files and no damage. Pass
  `--no-color`.

Malformed, truncated, or adversarial input never traps or throws. The
parser repairs damage locally or abandons the damaged file, picks up
again at the next file, and reports each case as a `DamageReport`; its
own buffers stay bounded however long a line or header block runs.
Seeded mutation tests and a libFuzzer target check these guarantees;
[SECURITY.md](SECURITY.md) has the details.

Results are checked against git: on the Linux kernel, redis, and
swift-argument-parser diffs, every file's line counts match
`git apply --numstat`, headers match `git apply --summary`, and the full
model renders each diff back to its input byte for byte.

## Requirements

- Swift 6.2 or later.
- macOS, iOS, tvOS, watchOS, or visionOS 26, whose standard library has
  `Span`; or Linux. CI tests macOS and Ubuntu (the `swift:6.2` image).
- No dependencies.

## Documentation

The DocC catalog in
[Sources/GitDiffKit/GitDiffKit.docc](Sources/GitDiffKit/GitDiffKit.docc)
has the articles — [Getting Started](Sources/GitDiffKit/GitDiffKit.docc/GettingStarted.md),
[Choosing a Collector](Sources/GitDiffKit/GitDiffKit.docc/ChoosingACollector.md),
[Streaming Large Diffs](Sources/GitDiffKit/GitDiffKit.docc/Streaming.md),
and [Handling Damaged Input](Sources/GitDiffKit/GitDiffKit.docc/DamagedInput.md)
— and every public symbol is documented. To read it rendered, open the
package in Xcode and choose Product › Build Documentation, or run:

```sh
xcodebuild docbuild -scheme git-diff-parser -destination platform=macOS -derivedDataPath .build/docs
```

and open `.build/docs/Build/Products/Debug/GitDiffKit.doccarchive`.

- [INTERNALS.md](INTERNALS.md): how the parser works, its benchmarks,
  and how it is validated.
- [docs/diff-model.md](docs/diff-model.md): the design of the layered
  model, with the measurements behind it.
- [CONTRIBUTING.md](CONTRIBUTING.md): building, testing, and the house
  style. [AGENTS.md](AGENTS.md) has the full conventions.

Tools built on this library — filtering build and lint diagnostics to
the lines a pull request changes — live in
[swift-steward](https://github.com/marosoaie/swift-steward).

## License

[MIT](LICENSE). One test fixture comes from the Swift project and keeps
its own licence: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
