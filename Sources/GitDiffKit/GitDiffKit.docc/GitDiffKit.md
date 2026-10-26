# ``GitDiffKit``

Parse unified git diffs into the files and lines they touch, as they
stream in.

## Overview

GitDiffKit reads the output of `git diff`, `git show`, `git log -p`,
`git format-patch`, and plain `diff -u`, and tells you what it changes:
which lines each file adds, each file's status and line counts, or the
whole diff with every line's content.

```swift
import GitDiffKit

let changes = ChangedLines(diff: diffText)
if changes.contains(line: 3, in: "Sources/App/Greeting.swift") {
    print("line 3 of Greeting.swift is new or changed")
}
```

- **Streaming.** Feed the diff in chunks of any size, split anywhere,
  even inside a UTF-8 character. The result is the same for any
  chunking, and working memory stays bounded however large the input.
- **Three collectors.** ``ChangedLines`` records added lines per file,
  ``DiffSummary`` each file's status and line counts, and ``Diff`` the
  full model, which renders git's output back byte for byte, merges'
  combined diffs aside. A ``DiffEventConsumer`` of your own sees every
  event.
- **Safe on hostile input.** Malformed, truncated, or adversarial diffs
  never trap and never throw: the parser repairs what it can, abandons
  a file it can't read, reports both as ``DamageReport``s, and carries
  on with the next file.
- **Checked against git.** On the Linux kernel, redis, and
  swift-argument-parser diffs, per-file results match
  `git apply --numstat` and `--summary`, and the full model renders each
  diff back to its input.
- **No dependencies, no Foundation.** Builds on every Apple platform
  (the 26 releases) and on Linux, with Swift 6.2 or later.

Start with <doc:GettingStarted>, then pick a collector with
<doc:ChoosingACollector>.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ChoosingACollector>
- <doc:Streaming>
- <doc:DamagedInput>

### Changed Lines

- ``ChangedLines``
- ``LineRangeSet``
- ``DiffParser``

### File Summaries

- ``DiffSummary``

### The Full Model

- ``Diff``
- ``DiffFile``
- ``DiffHunk``
- ``DiffLine``
- ``DiffTextLine``

### File Headers

- ``FileHeader``
- ``Change``
- ``DiffPath``
- ``FileMode``
- ``ObjectID``

### Events

- ``DiffEventParser``
- ``DiffEventConsumer``
- ``LineInfo``
- ``HunkHeader``
- ``ParsingOptions``

### Damage

- ``DamageReport``
