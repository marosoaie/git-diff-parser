import Foundation
@testable import GitDiffKit

extension ChangedLines {
    /// Expanded per-file line sets — convenient for asserting on small fixtures.
    var lineSets: [String: Set<Int>] {
        files.mapValues { Set($0.ranges.flatMap { Array($0) }) }
    }
}

/// Runs the git-diff-parser executable that the test build produces into the
/// build products directory.
enum CommandLineTool {
    static var url: URL? {
        // The products directory looks different per test runner, so try two
        // anchors:
        // - `swift test`: Bundle.module sits directly in the products
        //   directory (the .xctest is never registered as a bundle there —
        //   the Swift Testing host is a runner binary in the toolchain).
        // - Xcode / xcodebuild: Bundle.module resolves to a copy embedded in
        //   GitDiffKitTests.xctest/Contents/Resources with no executables
        //   nearby, but the loaded .xctest bundle itself sits in the
        //   products directory.
        var candidates = [Bundle.module.bundleURL.deletingLastPathComponent()]
        candidates += Bundle.allBundles
            .filter { $0.bundleURL.pathExtension == "xctest" }
            .map { $0.bundleURL.deletingLastPathComponent() }
        for directory in candidates {
            let url = directory.appendingPathComponent("git-diff-parser")
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func run(arguments: [String]) throws -> Data {
        guard let tool = url else {
            throw FixtureError("git-diff-parser executable not built alongside tests")
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        // Drain before waiting, or a full pipe buffer deadlocks the child.
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError(
                "git-diff-parser \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)"
            )
        }
        return output
    }
}

/// Minimal JSON shape of a `changes --format json` entry, shared by the CLI
/// end-to-end tests.
struct ChangesEntry: Decodable {
    var path: String
    var lineCount: Int
}
