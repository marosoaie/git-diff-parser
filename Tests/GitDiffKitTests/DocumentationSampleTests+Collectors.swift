import Foundation
import GitDiffKit
import Testing

/// The samples of Choosing a Collector.
extension DocumentationSampleTests {
    @Test("Choosing a Collector: warnings on changed lines")
    func changedLinesFilter() {
        var printedLines: [String] = []
        func print(_ items: Any...) { printedLines.append(Self.printed(items)) }

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

        #expect(printedLines == [#"["unused variable"]"#])
    }

    @Test("Choosing a Collector: a summary of each file")
    func summary() {
        var printedLines: [String] = []
        func print(_ items: Any...) { printedLines.append(Self.printed(items)) }

        let summary = DiffSummary(diff: diffText)
        summary.files.forEach { file in
            let path = file.header.newPath ?? file.header.oldPath
            print(file.header.change, path?.string ?? "?", file.addedLineCount, file.deletedLineCount)
        }
        // modified Sources/App/Greeting.swift 2 1
        // modified README.md 1 0
        // deleted Sources/App/Legacy.swift 0 2

        #expect(printedLines == [
            "modified Sources/App/Greeting.swift 2 1",
            "modified README.md 1 0",
            "deleted Sources/App/Legacy.swift 0 2",
        ])
    }

    @Test("Choosing a Collector: the full model, rendered back")
    func fullModel() throws {
        var printedLines: [String] = []
        func print(_ items: Any...) { printedLines.append(Self.printed(items)) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-docs-\(UUID().uuidString).diff")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)

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

        let text = [UInt8](rendering: diff)
        print(text == Array(diffText.utf8))   // true

        let swiftFiles = Diff(files: diff.files.filter { file in
            file.header.newPath?.string.hasSuffix(".swift") ?? false
        })
        try swiftFiles.render { chunk in
            try output.write(contentsOf: chunk)
        }

        try output.close()
        #expect(printedLines == [
            #"Sources/App/Greeting.swift:2:     var text = "Hello, world""#,
            #"Sources/App/Greeting.swift:3:     var punctuation = "!""#,
            "README.md:13: Pass a name to greet someone.",
            "true",
        ])
        // Only Greeting.swift: README.md isn't Swift, and Legacy.swift has
        // no new path.
        let readme = try #require(diffText.range(of: "diff --git a/README.md"))
        #expect(try String(contentsOf: url, encoding: .utf8) == diffText[..<readme.lowerBound])
    }
}
