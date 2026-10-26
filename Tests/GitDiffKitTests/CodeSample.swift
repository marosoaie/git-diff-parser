import Foundation

/// A fenced ```` ```swift ```` block from the documentation: a Markdown
/// file, or a doc comment in the library's sources.
struct CodeSample: CustomStringConvertible {
    /// The file's path relative to the repository root.
    var file: String
    /// The 1-based line of the opening fence.
    var line: Int
    /// The block's lines, without the fences, the doc-comment slashes, or
    /// the indentation of the fence.
    var lines: [String]

    var description: String { "\(file):\(line)" }

    /// Whether the sample is a package manifest, which only SwiftPM can
    /// compile.
    var isManifest: Bool { lines.first?.hasPrefix("// swift-tools-version") == true }

    /// The modules the sample imports before its code.
    var imports: [String] {
        lines.prefix { $0.hasPrefix("import ") }.map { String($0.dropFirst("import ".count)) }
    }

    /// The sample without its imports and the blank line after them, which
    /// a test file has at its top instead.
    var code: ArraySlice<String> {
        lines.drop { $0.hasPrefix("import ") || $0.isEmpty }
    }

    /// Whether `source` holds the sample's code as consecutive lines,
    /// indented alike by however much more than the sample.
    func appears(in source: [String]) -> Bool {
        let code = Array(code)
        guard let first = code.first, code.count <= source.count else { return code.isEmpty }
        return source.indices.dropLast(code.count - 1).contains { start in
            let shift = Self.indentation(of: source[start]) - Self.indentation(of: first)
            guard shift >= 0 else { return false }
            let indent = String(repeating: " ", count: shift)
            return zip(code, source[start...]).allSatisfy { sample, candidate in
                sample.isEmpty ? candidate.allSatisfy { $0 == " " } : candidate == indent + sample
            }
        }
    }

    private static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}

extension CodeSample {
    /// The repository checkout these tests were compiled from.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Markdown files whose Swift samples must compile, relative to the
    /// repository root; the design docs' API sketches are left out.
    static let markdownFiles = ["README.md", "CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md"]
    static let catalog = "Sources/GitDiffKit/GitDiffKit.docc"
    static let sources = "Sources/GitDiffKit"

    /// Every Swift sample in the documentation: the Markdown files, the
    /// DocC catalog's articles, and the library's doc comments.
    static func documented() throws -> [CodeSample] {
        let articles = try files(in: catalog, withExtension: "md")
        let markdown = try (markdownFiles + articles).flatMap { file in
            samples(in: numberedLines(of: try contents(of: file)), file: file)
        }
        let docComments = try files(in: sources, withExtension: "swift").flatMap { file in
            samples(in: docCommentLines(of: try contents(of: file)), file: file)
        }
        return markdown + docComments
    }

    /// The lines of the files whose names start with `prefix` in this test
    /// target, one array per file.
    static func testSources(named prefix: String) throws -> [[String]] {
        try files(in: "Tests/GitDiffKitTests", withExtension: "swift")
            .filter { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(prefix) }
            .map { file in numberedLines(of: try contents(of: file)).map(\.text) }
    }

    static func contents(of file: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
    }

    private static func files(in directory: String, withExtension pathExtension: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: repositoryRoot.appendingPathComponent(directory).path)
            .filter { $0.hasSuffix(".\(pathExtension)") }
            .sorted()
            .map { "\(directory)/\($0)" }
    }

    private static func numberedLines(of text: String) -> [(number: Int, text: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { ($0.offset + 1, String($0.element)) }
    }

    /// The text of each doc-comment line, after `///` and one space.
    private static func docCommentLines(of text: String) -> [(number: Int, text: String)] {
        numberedLines(of: text).compactMap { number, line in
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("///") else { return nil }
            let comment = trimmed.dropFirst(3)
            return (number, String(comment.first == " " ? comment.dropFirst() : comment))
        }
    }

    private static func samples(in lines: [(number: Int, text: String)], file: String) -> [CodeSample] {
        var samples: [CodeSample] = []
        // The open block and its fence's indentation: a cursor over the
        // lines, which a fold would only obscure.
        var open: (sample: CodeSample, indentation: Int)?
        lines.forEach { number, text in
            let trimmed = text.drop { $0 == " " }
            if var block = open {
                if trimmed == "```" {
                    samples.append(block.sample)
                    open = nil
                } else {
                    block.sample.lines.append(String(text.dropFirst(min(block.indentation, indentation(of: text)))))
                    open = block
                }
            } else if trimmed == "```swift" {
                open = (CodeSample(file: file, line: number, lines: []), text.count - trimmed.count)
            }
        }
        return samples
    }
}
