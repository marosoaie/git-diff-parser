import Foundation
import GitDiffKit
import Testing

/// Every Swift sample in the documentation, compiled and run.
///
/// The samples are copied into this file and its `+` extensions verbatim,
/// each in a test that checks what its comments say it prints. The first
/// test fails when a sample in the docs no longer appears here, so a
/// sample can't change without its test. These files import GitDiffKit
/// without `@testable`, so a sample can't use internal API.
@Suite("Documentation samples")
struct DocumentationSampleTests {
    /// The diff the articles use, from Getting Started.
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

    @Test("every Swift sample in the docs is in these tests, so it compiles and runs")
    func everySampleIsHere() throws {
        let tests = try CodeSample.testSources(named: "DocumentationSampleTests")
        let samples = try CodeSample.documented().filter { !$0.isManifest }
        let missing = samples.filter { sample in !tests.contains { sample.appears(in: $0) } }
        #expect(missing.map(\.description) == [])
        let imported = Set(tests.flatMap { lines in
            lines.filter { $0.hasPrefix("import ") }.map { String($0.dropFirst("import ".count)) }
        })
        #expect(Set(samples.flatMap(\.imports)).subtracting(imported) == [])
    }

    @Test("the check finds the samples in every kind of document")
    func samplesAreFound() throws {
        let files = Set(try CodeSample.documented().map(\.file))
        let expected = [
            "README.md",
            "\(CodeSample.catalog)/GitDiffKit.md",
            "\(CodeSample.catalog)/GettingStarted.md",
            "\(CodeSample.catalog)/ChoosingACollector.md",
            "\(CodeSample.catalog)/Streaming.md",
            "\(CodeSample.catalog)/DamagedInput.md",
            "\(CodeSample.sources)/DiffParser.swift",
            "\(CodeSample.sources)/Diff+Rendering.swift",
        ]
        #expect(Set(expected).subtracting(files) == [])
    }

    @Test(
        "every manifest sample is a manifest SwiftPM accepts, depending on this package's product",
        .timeLimit(.minutes(2))
    )
    func manifestSamplesParse() throws {
        let manifests = try CodeSample.documented().filter(\.isManifest)
        #expect(!manifests.isEmpty)
        let ownManifest = try CodeSample.contents(of: "Package.swift")
        try manifests.forEach { sample in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("git-diff-parser-manifest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try sample.lines.joined(separator: "\n")
                .write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            let dump = try Subprocess.output(of: ["swift", "package", "dump-package"], in: directory)
            let manifest = try #require(try JSONSerialization.jsonObject(with: dump) as? [String: Any])
            let dependencies = try #require(manifest["dependencies"] as? [[String: Any]])
            let sourceControl = try #require(dependencies.first?["sourceControl"] as? [[String: Any]])
            let location = try #require(sourceControl.first?["location"] as? [String: Any])
            let remote = try #require(location["remote"] as? [[String: Any]])
            #expect(remote.first?["urlString"] as? String == "https://github.com/marosoaie/git-diff-parser.git",
                    "\(sample)")
            let targets = try #require(manifest["targets"] as? [[String: Any]])
            let products = targets.flatMap { target in
                (target["dependencies"] as? [[String: Any]] ?? []).compactMap { $0["product"] as? [Any] }
            }
            let product = try #require(products.first, "\(sample) depends on no product")
            #expect(product.first as? String == "GitDiffKit", "\(sample)")
            #expect(product.dropFirst().first as? String == sourceControl.first?["identity"] as? String,
                    "\(sample)")
            #expect(ownManifest.contains(".library(name: \"GitDiffKit\""))
        }
    }

    /// Splits `text` into chunks of `size` bytes, the last one shorter.
    static func chunks(of text: String, size: Int) -> [[UInt8]] {
        let bytes = Array(text.utf8)
        return stride(from: 0, to: bytes.count, by: size).map { Array(bytes[$0..<min($0 + size, bytes.count)]) }
    }

    /// What `print` would write for `items`.
    static func printed(_ items: [Any]) -> String {
        items.map { "\($0)" }.joined(separator: " ")
    }
}
