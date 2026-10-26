# Streaming Large Diffs

Parse a diff as it arrives, in chunks of any size, and see it as events.

## Overview

Every collector streams. A ``DiffEventParser`` takes the diff a chunk at
a time and calls its consumer's methods as it reads: a file begins, a
hunk begins, a line, the file ends. Chunks can be any size and end
anywhere, even inside a line or a multi-byte UTF-8 character, and the
events are the same for any chunking.

The parser's own working memory is bounded whatever the input: by the
line cap (1 MiB by default, see ``ParsingOptions``) for a line that
spans chunks, and by 64 lines and 1 MiB for a file's header block. What
grows is what the consumer keeps — see <doc:ChoosingACollector>.

### Feed the parser

Create a parser with the collector you want, call
``DiffEventParser/consume(_:)-([UInt8])`` for each chunk, and
``DiffEventParser/finalize()`` once at the end, which returns the
consumer:

```swift
var parser = DiffEventParser(consumer: DiffSummary.Collector())
while let chunk = readSomeBytes() {
    parser.consume(chunk)
}
let summary = parser.finalize().summary
```

Chunks can be `[UInt8]`, `ArraySlice<UInt8>`, or `String`. The full
model has its own initializer, which raises the line cap to 64 MiB:

```swift
var parser = DiffEventParser<Diff.Collector>()
parser.consume(diffText)
let diff = parser.finalize().diff
```

``DiffParser`` is the same for ``ChangedLines``, kept from GitDiffKit's
first release; `DiffEventParser(consumer: ChangedLines.Collector())`
does the same job.

### Read a file or standard input

GitDiffKit doesn't import Foundation, but on Apple platforms and Linux
you will usually read with `FileHandle`. This reads 4 MiB at a time,
from a file or from standard input when your tool sits at the end of a
pipe (`git diff | review-bot`):

```swift
import Foundation
import GitDiffKit

func summarize(readingFrom handle: FileHandle) throws -> DiffSummary {
    var parser = DiffEventParser(consumer: DiffSummary.Collector())
    while let chunk = try nextChunk(of: handle) {
        parser.consume([UInt8](chunk))
    }
    return parser.finalize().summary
}

func nextChunk(of handle: FileHandle) throws -> Data? {
    #if canImport(Darwin)
    // On Darwin, `read(upToCount:)` returns autoreleased data. Without a
    // pool per read, every chunk lives until an outer pool drains, often
    // at exit, and streaming quietly holds the whole file in memory.
    let chunk = try autoreleasepool { try handle.read(upToCount: 4 << 20) }
    #else
    let chunk = try handle.read(upToCount: 4 << 20)
    #endif
    return chunk?.isEmpty == false ? chunk : nil
}
```

Call it with `try summarize(readingFrom: .standardInput)`, or with
`try FileHandle(forReadingFrom: url)` for a file.

> Important: Wrap each `FileHandle` read in an `autoreleasepool` on
> Apple platforms, as above. Without it, memory grows with the file
> however little the consumer keeps. Linux has no autorelease pool and
> no such problem.

### Read an async sequence

The parser is synchronous: with an asynchronous source, call
``DiffEventParser/consume(_:)-([UInt8])`` from your own loop:

```swift
func summarize(_ chunks: some AsyncSequence<[UInt8], any Error>) async throws -> DiffSummary {
    var parser = DiffEventParser(consumer: DiffSummary.Collector())
    for try await chunk in chunks {
        parser.consume(chunk)
    }
    return parser.finalize().summary
}
```

A parser is a value, and it is `Sendable` when its consumer is, as the
library's collectors are. Parse several diffs at once with one parser
each.

### Write your own consumer

A ``DiffEventConsumer`` takes the events it needs; every method has an
empty default. This one finds the added lines that mention `TODO`:

```swift
struct AddedTODOs: DiffEventConsumer {
    var found: [String] = []
    private var path = ""

    mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>) {
        path = header.newPath?.string ?? ""
    }

    mutating func line(_ line: LineInfo, content: Span<UInt8>) {
        guard line.kind == .addition, let number = line.newNumber else { return }
        if String(decodingLossily: content).contains("TODO") {
            found.append("\(path):\(number)")
        }
    }
}

var parser = DiffEventParser(consumer: AddedTODOs())
parser.consume("""
    diff --git a/Sources/App/Cache.swift b/Sources/App/Cache.swift
    --- a/Sources/App/Cache.swift
    +++ b/Sources/App/Cache.swift
    @@ -7,2 +7,3 @@ struct Cache {
         var entries: [String: Entry] = [:]
    +    // TODO: evict old entries.
     }
    """)
print(parser.finalize().found)   // ["Sources/App/Cache.swift:8"]
```

**Content arrives as a `Span<UInt8>`**, a view of the parser's own
buffers that is valid only during the call, so no line is copied unless
you copy it. The compiler won't let a span escape the call; to keep the
bytes, copy them with ``Swift/Array/init(copying:)``, or decode them
with ``Swift/String/init(decodingLossily:)``, which replaces invalid
UTF-8 with U+FFFD. Content never includes the line's marker column, its
`\r`, or its `\n`; ``LineInfo`` flags the `\r` and a line cut at the
cap.

**The events come in input order.** ``DiffEventConsumer/beginFile(_:rawHeader:)``
comes once a file's header block is complete, then its hunks
(``DiffEventConsumer/beginHunk(_:heading:)`` and its
``DiffEventConsumer/line(_:content:)``s) or the lines of a binary patch,
then ``DiffEventConsumer/endFile()``. Every `beginFile` gets its
`endFile`, so a consumer never tracks file boundaries itself.
``DiffEventConsumer/unrecognizedLine(_:endsWithCarriageReturn:)`` and
``DiffEventConsumer/damage(_:)`` can come anywhere in between, and
``DiffEventConsumer/noNewlineAtEndOfInput()`` comes last, if at all.

**A combined diff's file gets `beginFile` and `endFile`** but no hunk or
line events, since combined diffs are skipped (see
<doc:ChoosingACollector#Merges>).

### Set the line cap

The parser reads at most ``ParsingOptions/maximumLineLength`` bytes of a
line, 1 MiB by default, and flags a longer line
``LineInfo/isTruncated``. The cap bounds the buffer that carries a line
across chunks, so input with no newlines can't grow memory without
limit. A consumer that keeps content may want more:

```swift
let options = ParsingOptions(maximumLineLength: 16 << 20)
var parser = DiffEventParser(consumer: AddedTODOs(), options: options)
```

The full model's entry points use ``ParsingOptions/fullModel``, which
raises the cap to 64 MiB. A collector that only counts lines needs no
more than the default: a truncated line still counts once.

## See Also

- ``DiffEventParser``
- ``DiffEventConsumer``
- <doc:DamagedInput>
