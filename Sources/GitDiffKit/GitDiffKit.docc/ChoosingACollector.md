# Choosing a Collector

Keep as much of a diff as you need: its changed lines, a summary of each
file, or all of it.

## Overview

A collector is a ``DiffEventConsumer`` that keeps part of what the
parser reads. GitDiffKit ships three, from least to most:

| | ``ChangedLines`` | ``DiffSummary`` | ``Diff`` |
|---|---|---|---|
| Keeps | Each file's added lines, as ranges of new-side numbers | Each file's header (status, paths, modes) and its added and deleted line counts | Everything: headers, hunks, every line's content, and the text around them |
| Paths | `String` | ``DiffPath`` (bytes) | ``DiffPath`` (bytes) |
| Memory grows with | The number of edits | The number of files | The diff's content, about 2.5× its size |
| Damage reports | Not kept | Kept | Kept |
| Kernel diff, 74 MB | 0.11 s, 22 MB | 0.13 s, 24 MB | 0.20 s, 187 MB |
| Kernel diff ×6, 443 MB | 0.56 s, 19 MB | 0.76 s, 59 MB | 1.25 s, 1.1 GB |

The last two rows were measured on the Linux 6.6→6.7 release diff
(13,479 files) and on six copies of it, read in 4 MiB chunks by a
release build on an Apple M4 with Swift 6.4. Memory is the process's
peak resident size, the input buffer included. ``ChangedLines`` stays
flat as the input grows, the summary grows with the file count (about
500 bytes per file), and the full model with the content. On hostile
input, the damage reports the summary and the full model keep can grow
with the input too.

Pick the least that answers your question. The examples below parse the
`diffText` from <doc:GettingStarted>, which edits `Greeting.swift`,
adds a line to `README.md`, and deletes `Legacy.swift`.

### Changed lines

``ChangedLines`` is for questions about lines: is this warning on a line
the diff changed? It records only added lines, under each file's new
path, so it is small and flat however large the diff:

```swift
struct Warning {
    var path: String
    var line: Int
    var message: String
}

let warnings = [
    Warning(path: "Sources/App/Greeting.swift", line: 3, message: "unused variable"),
    Warning(path: "Sources/App/Greeting.swift", line: 9, message: "line too long"),
    Warning(path: "Sources/App/Legacy.swift", line: 1, message: "file deleted"),
]
let changes = ChangedLines(diff: diffText)
let onChangedLines = warnings.filter { changes.contains(line: $0.line, in: $0.path) }
print(onChangedLines.map(\.message))   // ["unused variable"]
```

Its rules — new-side numbers, additions only, `String` paths that
compare by Unicode canonical equivalence — are in
<doc:GettingStarted#What-counts-as-changed>.

### A summary of each file

``DiffSummary`` is for questions about files: what was added, deleted,
renamed, or made executable, and how many lines each file adds and
deletes. It holds what `git apply --summary` and `git apply --numstat`
print:

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

Each file's ``FileHeader`` has its ``Change`` (added, deleted, modified,
renamed, or copied, with git's similarity), both paths, both modes and
``FileHeader/modeChanged``, the object IDs from the `index` line,
``FileHeader/isBinary``, and a rewrite's dissimilarity. Every file is
listed, deleted and binary ones included; a binary file counts no lines.
Its memory grows with the number of files, not with their content;
only its `damage` list can grow with a hostile input's lines (see
<doc:DamagedInput>).

### The full model

``Diff`` keeps everything, for tools that read the content: which text
a line adds, what a hunk's heading says, or the diff rewritten with
some files left out. Each ``DiffFile`` has its header, its hunks
(``DiffHunk``), and their lines (``DiffLine``), with content as bytes:

```swift
let diff = Diff(diff: diffText)
diff.files.forEach { file in
    let path = file.header.newPath?.string ?? "?"
    file.lines.filter { $0.info.kind == .addition }.forEach { line in
        print("\(path):\(line.info.newNumber ?? 0):", String(decoding: line.content, as: UTF8.self))
    }
}
// Sources/App/Greeting.swift:2:     var text = "Hello, world"
// Sources/App/Greeting.swift:3:     var punctuation = "!"
// README.md:13: Pass a name to greet someone.
```

Content is bytes because a file's content can be in any encoding;
decode it as you see fit. Lines a parser can't place — a commit
message, mail headers, `Only in …` — are kept where they appeared: in
``Diff/preamble`` before the first file, in a file's
``DiffFile/leadingLines`` before its first hunk, and in a hunk's
``DiffHunk/trailingLines`` after it.

**Its memory grows with the diff's content.** The model keeps every
byte, packed per file, and peaks at about 2.5× the diff's size: 187 MB
for the kernel's 74 MB diff, 1.1 GB for six copies. A line, hunk, or
any other element you hold keeps its whole file's storage alive. Its
entry points, ``Diff/init(diff:)-(String)`` and
``DiffEventParser/init(options:)``, raise the line cap from 1 MiB to
64 MiB (``ParsingOptions/fullModel``), so content is kept whole up to
that length. For diffs too large to hold, use a summary,
``ChangedLines``, or a consumer of your own, whose memory doesn't grow
with content.

### Render a diff back

``Diff/render(_:)`` writes the model back as unified diff text, in
chunks of about 64 KiB, and ``Swift/Array/init(rendering:)`` builds the
text whole. For a diff parsed from git's output, or from plain
`diff -u`, the text is the input byte for byte, and git applies it as it
would the input:

```swift
let text = [UInt8](rendering: diff)
print(text == Array(diffText.utf8))   // true
```

A file renders from its raw header, never from its ``FileHeader``, so
to render some of the files, render a diff of them:

```swift
let swiftFiles = Diff(files: diff.files.filter { file in
    file.header.newPath?.string.hasSuffix(".swift") ?? false
})
try swiftFiles.render { chunk in
    try output.write(contentsOf: chunk)
}
```

The text differs from the input only where the model doesn't keep it:

- A combined diff (`diff --cc`) renders as its header alone, since its
  hunks are skipped.
- Damaged input renders as the model holds it: an abandoned file is
  missing, and a line cut at the line cap stays cut.
- A localized `\ No newline at end of file` comes out in English.
- Hunk header numbers lose leading zeros, which git never writes.

### Merges

All three skip the hunks of a merge's combined diff (`diff --cc` or
`diff --combined`, which `git show` prints for a merge commit): the
parser recognizes them, so their lines can't be mistaken for another
file's, but reports no lines for them. ``ChangedLines`` gets nothing
from such a file; ``DiffSummary`` and ``Diff`` list it with format
``FileHeader/Format-swift.enum/combined(parents:)``, no line counts,
and no hunks. For the lines a merge changed, diff it against its first
parent (`git show --diff-merges=first-parent`) or use a three-dot diff.

### Something else

For anything else — a few events, an answer none of the three gives,
or two collectors fed from one pass over the input — implement a
``DiffEventConsumer`` and drive it with a ``DiffEventParser``. Its
methods all have defaults, so it takes only the events it needs; see
<doc:Streaming#Write-your-own-consumer>.

## See Also

- <doc:Streaming>
- <doc:DamagedInput>
