import Foundation
import Testing
@testable import GitDiffKit

/// Regression tests against a real-world diff: swiftlang/swift PR #70000
/// (Apache 2.0), fetched from https://github.com/swiftlang/swift/pull/70000.diff.
///
/// The expected totals were independently verified with git's own patch
/// parser: `git apply --numstat` reports the same 12 files and the same
/// per-file added-line counts.
@Suite("Real-world diff")
struct RealDiffTests {
    static func loadFixture() throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: "swift-pr-70000", withExtension: "diff", subdirectory: "Fixtures"
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("swiftlang/swift PR #70000 parses to numstat-verified totals")
    func swiftPR70000() throws {
        let changes = ChangedLines(diff: try Self.loadFixture())

        #expect(changes.files.count == 12)
        #expect(changes.files.values.reduce(0) { $0 + $1.lineCount } == 437)

        // Spot checks.
        #expect(changes.ranges(in: "include/swift/AST/Types.h") == [4788...4790])
        #expect(changes.ranges(in: "test/SILOptimizer/simplify_cfg_ossa.sil") == [1791...1845])
        #expect(changes.ranges(in: "SwiftCompilerSources/Sources/SIL/Function.swift")
            == [59...60, 69...71])
    }

    @Test("real diff parses identically through any chunking")
    func chunkedRealDiff() throws {
        let fixture = try Self.loadFixture()
        let wholeString = ChangedLines(diff: fixture)

        let bytes = Array(fixture.utf8)
        for chunkSize in [1, 379, 4096] {
            var parser = DiffParser()
            var index = 0
            while index < bytes.count {
                let end = min(index + chunkSize, bytes.count)
                parser.consume(bytes[index..<end])
                index = end
            }
            #expect(parser.finalize() == wholeString, "chunk size \(chunkSize)")
        }
    }
}
