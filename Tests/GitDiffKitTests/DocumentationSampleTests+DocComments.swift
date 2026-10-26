import Foundation
import GitDiffKit
import Testing

/// The samples in the library's doc comments.
extension DocumentationSampleTests {
    @Test("DiffParser: streaming changed lines")
    func diffParserSample() {
        var chunks = Self.chunks(of: diffText, size: 3)
        func readSomeBytes() -> [UInt8]? { chunks.isEmpty ? nil : chunks.removeFirst() }

        var parser = DiffParser()
        while let chunk = readSomeBytes() { parser.consume(chunk) }
        let changes = parser.finalize()

        #expect(changes == ChangedLines(diff: diffText))
    }

    @Test("ChangedLines.Collector: driving it with the event parser")
    func changedLinesCollectorSample() {
        let diffBytes = Array(diffText.utf8)

        var parser = DiffEventParser(consumer: ChangedLines.Collector())
        parser.consume(diffBytes)
        let changes = parser.finalize().changedLines

        #expect(changes == ChangedLines(diff: diffText))
    }

    @Test("DiffEventParser: any consumer")
    func eventParserSample() {
        var chunks = Self.chunks(of: diffText, size: 3)
        func readSomeBytes() -> [UInt8]? { chunks.isEmpty ? nil : chunks.removeFirst() }
        struct MyCollector: DiffEventConsumer {
            var files = 0
            mutating func endFile() { files += 1 }
        }

        var parser = DiffEventParser(consumer: MyCollector())
        while let chunk = readSomeBytes() { parser.consume(chunk) }
        let collector = parser.finalize()

        #expect(collector.files == 3)
    }

    @Test("DiffSummary: the files a diff deletes")
    func summarySample() {
        let summary = DiffSummary(diff: diffText)
        let deleted = summary.files.filter { $0.header.change == .deleted }

        #expect(deleted.map(\.header.oldPath?.string) == ["Sources/App/Legacy.swift"])
    }

    @Test("DiffSummary.Collector: streaming a summary")
    func summaryCollectorSample() {
        var chunks = Self.chunks(of: diffText, size: 3)
        func readSomeBytes() -> [UInt8]? { chunks.isEmpty ? nil : chunks.removeFirst() }

        var parser = DiffEventParser(consumer: DiffSummary.Collector())
        while let chunk = readSomeBytes() { parser.consume(chunk) }
        let summary = parser.finalize().summary

        #expect(summary == DiffSummary(diff: diffText))
    }

    @Test("Diff.Collector: streaming the full model")
    func fullModelCollectorSample() {
        var chunks = Self.chunks(of: diffText, size: 3)
        func readSomeBytes() -> [UInt8]? { chunks.isEmpty ? nil : chunks.removeFirst() }

        var parser = DiffEventParser<Diff.Collector>()
        while let chunk = readSomeBytes() { parser.consume(chunk) }
        let diff = parser.finalize().diff

        #expect(diff == Diff(diff: diffText))
    }

    @Test("Diff.render(_:) and [UInt8](rendering:): the input back")
    func renderingSamples() throws {
        let input = Array(diffText.utf8)
        let diff = Diff(diff: input)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-docs-\(UUID().uuidString).diff")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)

        try diff.render { chunk in try handle.write(contentsOf: chunk) }
        let text = [UInt8](rendering: Diff(diff: input))   // == input

        try handle.close()
        #expect(text == input)
        #expect(try [UInt8](Data(contentsOf: url)) == input)
    }
}
