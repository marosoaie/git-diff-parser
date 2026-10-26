import Foundation
import GitDiffKit
import Testing

/// The samples of Streaming Large Diffs.
extension DocumentationSampleTests {
    @Test("Streaming: feeding the parser chunk by chunk", arguments: [1, 7, 4096])
    func feedTheParser(chunkSize: Int) {
        var chunks = Self.chunks(of: diffText, size: chunkSize)
        func readSomeBytes() -> [UInt8]? { chunks.isEmpty ? nil : chunks.removeFirst() }

        var parser = DiffEventParser(consumer: DiffSummary.Collector())
        while let chunk = readSomeBytes() {
            parser.consume(chunk)
        }
        let summary = parser.finalize().summary

        #expect(summary == DiffSummary(diff: diffText))
        #expect(summary.files.count == 3)
    }

    @Test("Streaming: the full model's parser")
    func fullModelParser() {
        var parser = DiffEventParser<Diff.Collector>()
        parser.consume(diffText)
        let diff = parser.finalize().diff

        #expect(diff == Diff(diff: diffText))
        #expect(diff.files.map(\.lines.count) == [6, 3, 2])
    }

    @Test("Streaming: reading a file through a FileHandle")
    func readAFile() throws {
        let url = try #require(Bundle.module.url(
            forResource: "swift-pr-70000", withExtension: "diff", subdirectory: "Fixtures"
        ))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let summary = try summarize(readingFrom: handle)

        let whole = DiffSummary(diff: try String(contentsOf: url, encoding: .utf8))
        #expect(summary == whole)
        #expect(!summary.files.isEmpty)
    }

    @Test("Streaming: reading an async sequence")
    func readAnAsyncSequence() async throws {
        let pieces = Self.chunks(of: diffText, size: 5)
        let chunks = AsyncThrowingStream<[UInt8], any Error> { continuation in
            pieces.forEach { continuation.yield($0) }
            continuation.finish()
        }

        let summary = try await summarize(chunks)

        #expect(summary == DiffSummary(diff: diffText))
    }

    @Test("Streaming: a consumer of your own")
    func ownConsumer() {
        var printedLines: [String] = []
        func print(_ items: Any...) { printedLines.append(Self.printed(items)) }

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

        #expect(printedLines == [#"["Sources/App/Cache.swift:8"]"#])

        // A to-do past the default 1 MiB cap is found only with the cap raised.
        let longLine = """
            diff --git a/a b/a
            --- a/a
            +++ b/a
            @@ -0,0 +1 @@
            +\(String(repeating: "x", count: 2 << 20)) TODO
            """
        var capped = DiffEventParser(consumer: AddedTODOs())
        capped.consume(longLine)
        #expect(capped.finalize().found == [])
        do {
            let options = ParsingOptions(maximumLineLength: 16 << 20)
            var parser = DiffEventParser(consumer: AddedTODOs(), options: options)

            parser.consume(longLine)
            #expect(parser.finalize().found == ["a:1"])
        }
    }

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

    func summarize(_ chunks: some AsyncSequence<[UInt8], any Error>) async throws -> DiffSummary {
        var parser = DiffEventParser(consumer: DiffSummary.Collector())
        for try await chunk in chunks {
            parser.consume(chunk)
        }
        return parser.finalize().summary
    }
}
