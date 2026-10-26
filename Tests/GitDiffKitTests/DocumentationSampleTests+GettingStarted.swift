import GitDiffKit
import Testing

/// The samples of the catalog's landing page and Getting Started.
extension DocumentationSampleTests {
    @Test("Overview: checking one line")
    func overview() {
        var printedLines: [String] = []
        func print(_ items: Any...) { printedLines.append(Self.printed(items)) }

        let changes = ChangedLines(diff: diffText)
        if changes.contains(line: 3, in: "Sources/App/Greeting.swift") {
            print("line 3 of Greeting.swift is new or changed")
        }

        #expect(printedLines == ["line 3 of Greeting.swift is new or changed"])
    }

    @Test("Getting Started: finding the changed lines")
    func gettingStartedChangedLines() {
        let changes = ChangedLines(diff: diffText)
        let paths = changes.sortedPaths   // ["README.md", "Sources/App/Greeting.swift"]
        let greeting = changes.ranges(in: "Sources/App/Greeting.swift")   // [2...3]
        let readme = changes.lines(in: "README.md")   // [13]

        let isChanged = changes.contains(line: 3, in: "Sources/App/Greeting.swift")   // true
        let isNextChanged = changes.contains(line: 4, in: "Sources/App/Greeting.swift")   // false
        let isNearChange = changes.contains(line: 4, in: "Sources/App/Greeting.swift", tolerance: 1)   // true

        #expect(paths == ["README.md", "Sources/App/Greeting.swift"])
        #expect(greeting == [2...3])
        #expect(readme == [13])
        #expect(isChanged && !isNextChanged && isNearChange)
    }

    @Test("Getting Started: reading large diffs in chunks gives the same result", arguments: [1, 7, 4096])
    func gettingStartedChunks(chunkSize: Int) {
        var chunks = Self.chunks(of: diffText, size: chunkSize)
        func readSomeBytes() -> [UInt8]? { chunks.isEmpty ? nil : chunks.removeFirst() }

        var parser = DiffParser()
        while let chunk = readSomeBytes() {
            parser.consume(chunk)
        }
        let streamed = parser.finalize()   // the same ChangedLines, for any chunking

        #expect(streamed == ChangedLines(diff: diffText))
    }
}
