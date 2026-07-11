import Foundation
@testable import GitDiffKit

extension ChangedLines {
    /// Expanded per-file line sets — convenient for asserting on small fixtures.
    var lineSets: [String: Set<Int>] {
        files.mapValues { Set($0.ranges.flatMap { Array($0) }) }
    }
}

/// Runs the git-diff-parser executable that `swift test` builds next to the
/// test bundle.
enum CommandLineTool {
    static var url: URL? {
        let url = Bundle.module.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("git-diff-parser")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
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
