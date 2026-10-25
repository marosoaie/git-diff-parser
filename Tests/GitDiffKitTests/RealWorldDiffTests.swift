import Foundation
import Testing
@testable import GitDiffKit

/// Validates the parser against large, real diffs from notorious projects.
///
/// Fixtures resolve from a local cache, downloading from kernel.org /
/// github.com on a miss. Set `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS` to skip
/// the whole suite.
@Suite(
    "Real-world large diffs",
    .serialized,
    .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil)
)
struct RealWorldDiffTests {
    @Test(
        "per-file changed-line counts match git apply --numstat",
        arguments: RealWorldFixture.allCases
    )
    func matchesGitNumstat(fixture: RealWorldFixture) async throws {
        let diffURL = try await RealWorldFixtureStore.localDiffURL(for: fixture)
        let changes = try Self.parseStreaming(contentsOf: diffURL)

        let ours = changes.files.mapValues(\.lineCount)
        let oracle = try GitNumstat.addedLineCounts(forDiffAt: diffURL)

        // Compare via an explicit mismatch list so a failure reports the
        // offending paths instead of dumping two 12k-entry dictionaries.
        let mismatched = Set(ours.keys).union(oracle.keys)
            .filter { ours[$0] != oracle[$0] }
            .sorted()
        #expect(ours.count == oracle.count)
        #expect(
            mismatched.isEmpty,
            "\(mismatched.count) files disagree with numstat; first: \(mismatched.prefix(5))"
        )
    }

    @Test(
        "headers and both numstat columns match git apply --summary and --numstat -z",
        arguments: RealWorldFixture.allCases
    )
    func matchesGitApply(fixture: RealWorldFixture) async throws {
        let diffURL = try await RealWorldFixtureStore.localDiffURL(for: fixture)
        var scanner = FileHeaderScanner()
        try Self.forEachChunk(of: diffURL) { scanner.consume($0) }
        let files = scanner.finalize()

        let summary = try GitApply.summary(forDiffAt: diffURL)
        #expect(!summary.isEmpty)
        Oracle.expectEqualLines(GitApply.summary(of: files), summary)
        Oracle.expectEqualEntries(GitApply.numstat(of: files), try GitApply.numstat(forDiffAt: diffURL))
    }

    @Test(
        "headers and line counts are the same for any chunking",
        arguments: [RealWorldFixture.redis, .swiftArgumentParser]
    )
    func chunkInvariance(fixture: RealWorldFixture) async throws {
        let diffURL = try await RealWorldFixtureStore.localDiffURL(for: fixture)
        let bytes = try Array(Data(contentsOf: diffURL))
        let whole = FileHeaderScanner.files(in: bytes)
        // One-byte chunks take seconds per megabyte in debug builds.
        let chunkSizes = [4093, (1 << 20) + 7] + (bytes.count < 1 << 20 ? [1] : [])
        chunkSizes.forEach { chunkSize in
            #expect(FileHeaderScanner.files(in: bytes, chunkSize: chunkSize) == whole, "chunk size \(chunkSize)")
        }
    }

    @Test("the kernel 6.6→6.7 release diff parses to its known totals")
    func kernelTotals() async throws {
        let diffURL = try await RealWorldFixtureStore.localDiffURL(for: .linuxKernel)
        let changes = try Self.parseStreaming(contentsOf: diffURL)
        #expect(changes.files.count == 12_057)
        #expect(changes.files.values.reduce(0) { $0 + $1.lineCount } == 906_147)
    }

    // MARK: Helpers

    /// Parses a diff file through the streaming interface in 4 MiB chunks,
    /// the same way the CLI does.
    static func parseStreaming(contentsOf url: URL) throws -> ChangedLines {
        var parser = DiffParser()
        try forEachChunk(of: url) { parser.consume($0) }
        return parser.finalize()
    }

    /// Reads the file at `url` in 4 MiB chunks, as the CLI does.
    static func forEachChunk(of url: URL, _ body: (ArraySlice<UInt8>) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try readChunk(from: handle), !chunk.isEmpty {
            body([UInt8](chunk)[...])
        }
    }

    private static func readChunk(from handle: FileHandle) throws -> Data? {
        #if canImport(Darwin)
        // FileHandle.read returns autoreleased Data; without a pool per read
        // every chunk lives until exit and the test reads the whole file.
        try autoreleasepool { try handle.read(upToCount: 4 << 20) }
        #else
        try handle.read(upToCount: 4 << 20)
        #endif
    }
}
