# Getting Started with GitDiffKit

Add the package, get a diff, and find out which lines it changes.

## Overview

The most common question about a diff is which lines it touches: a
linter or a code-review bot reports only the warnings on lines a pull
request changed. ``ChangedLines`` answers it, and it is where this
article starts. <doc:ChoosingACollector> covers the collectors that
keep more of the diff.

### Add the package

Add GitDiffKit to your package's dependencies and to the targets that
use it:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReviewBot",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/marosoaie/git-diff-parser.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ReviewBot",
            dependencies: [.product(name: "GitDiffKit", package: "git-diff-parser")]
        ),
    ]
)
```

GitDiffKit needs Swift 6.2 or later. On Apple platforms it needs the 26
releases (macOS, iOS, tvOS, watchOS, and visionOS), whose standard
library has `Span`; on Linux it has no floor. It has no dependencies and
doesn't import Foundation.

### Get a diff

For the changes a branch makes, diff it against its merge base with a
three-dot range, which leaves out whatever landed on the base branch in
the meantime:

```sh
git diff origin/main...HEAD > changes.diff
```

GitHub serves a pull request's diff at
`https://github.com/OWNER/REPO/pull/NUMBER.diff`. Any unified diff
works: `git show`, `git log -p`, `git format-patch` mail, and plain
`diff -u` or `diff -ruN` output too.

### Find the changed lines

Here is a small diff that edits one file, adds a line to another, and
deletes a third:

```swift
let diffText = """
    diff --git a/Sources/App/Greeting.swift b/Sources/App/Greeting.swift
    index 3b18e51..a2c4f0d 100644
    --- a/Sources/App/Greeting.swift
    +++ b/Sources/App/Greeting.swift
    @@ -1,4 +1,5 @@
     struct Greeting {
    -    var text = "Hello"
    +    var text = "Hello, world"
    +    var punctuation = "!"
         var name: String
     }
    diff --git a/README.md b/README.md
    index 5d0f7a1..9c2e4b8 100644
    --- a/README.md
    +++ b/README.md
    @@ -12,2 +12,3 @@ ## Usage
     Run the app.
    +Pass a name to greet someone.
     That's all.
    diff --git a/Sources/App/Legacy.swift b/Sources/App/Legacy.swift
    deleted file mode 100644
    index 7f3a2c1..0000000
    --- a/Sources/App/Legacy.swift
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -// Unused.
    -struct Legacy {}
    """
```

``ChangedLines/init(diff:)`` parses it and keeps, for each file, the
new-side line numbers it adds, as ranges:

```swift
let changes = ChangedLines(diff: diffText)
let paths = changes.sortedPaths   // ["README.md", "Sources/App/Greeting.swift"]
let greeting = changes.ranges(in: "Sources/App/Greeting.swift")   // [2...3]
let readme = changes.lines(in: "README.md")   // [13]

let isChanged = changes.contains(line: 3, in: "Sources/App/Greeting.swift")   // true
let isNextChanged = changes.contains(line: 4, in: "Sources/App/Greeting.swift")   // false
let isNearChange = changes.contains(line: 4, in: "Sources/App/Greeting.swift", tolerance: 1)   // true
```

``ChangedLines/contains(line:in:tolerance:)`` is a binary search over
the ranges. With a tolerance, it also matches lines near a changed one,
for tools that report a warning a line or two away from its cause.

### What counts as changed

``ChangedLines`` follows the rules a "warnings on changed lines" check
needs:

- **Line numbers are new-side numbers**, the ones in the changed files,
  in build logs, and in GitHub's pull request view.
- **Only added lines count.** Git writes a modified line as a deletion
  plus an addition, so additions cover both. A deleted line has no
  new-side number to report a warning on.
- **Only files with added lines appear.** Deleted and binary files never
  do, nor do files whose diff only deletes lines, renames them, or
  changes their mode. A renamed file with added lines appears under its
  new path.
- **Paths are as the diff names them**, with git's quoting undone and
  its `a/` and `b/` prefixes removed: for `git diff`, relative to the
  repository root (or to the directory `--relative` names); for plain
  `diff -ruN old new`, starting with `new/`.
- **Paths are `String` keys, decoded from git's bytes**, so they compare
  by Unicode canonical equivalence: the NFC and NFD spellings of one
  name, which git treats as two paths, share a key. Invalid UTF-8 is
  replaced with U+FFFD. ``DiffSummary`` and ``Diff`` keep paths as
  bytes, in ``DiffPath``.
- **Merges' combined diffs are skipped.** `git show` of a merge commit
  prints a combined diff (`diff --cc`), whose lines the parser
  recognizes but doesn't report. For the lines a merge changed, diff it
  against its first parent, with `git show --diff-merges=first-parent`,
  or use a three-dot diff as above.
- **CRLF diffs parse like LF ones**, and a line longer than 1 MiB is
  read cut to that length, so a pathological input can't grow memory
  without bound.

### Read large diffs in chunks

``ChangedLines/init(diff:)`` needs the whole diff in memory. For a large
one, feed it to a ``DiffParser`` a chunk at a time and finalize it
once; chunks can end anywhere, even inside a line:

```swift
var parser = DiffParser()
while let chunk = readSomeBytes() {
    parser.consume(chunk)
}
let streamed = parser.finalize()   // the same ChangedLines, for any chunking
```

<doc:Streaming> shows how to read a file, standard input, or an async
sequence this way, and how to write a consumer of your own.

## See Also

- <doc:ChoosingACollector>
- <doc:Streaming>
- ``ChangedLines``
