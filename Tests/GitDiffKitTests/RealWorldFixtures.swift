import Foundation
@testable import GitDiffKit

/// Large diffs from notorious open-source projects, used to validate the
/// parser against real-world input at scale.
enum RealWorldFixture: String, CaseIterable, Sendable {
    /// The Linux kernel v6.6 → v6.7 release patch from kernel.org —
    /// ~70 MB uncompressed, 12k files, ~900k added lines.
    case linuxKernel = "linux-6.6-to-6.7"
    /// GitHub's compare diff for redis 7.0.0 → 7.2.0 — ~7.6 MB, 1.1k files,
    /// includes renames.
    case redis = "redis-7.0.0-to-7.2.0"
    /// GitHub's compare diff for swift-argument-parser 1.0.0 → 1.5.0.
    case swiftArgumentParser = "swift-argument-parser-1.0.0-to-1.5.0"

    var remoteURL: URL {
        switch self {
        case .linuxKernel:
            URL(string: "https://cdn.kernel.org/pub/linux/kernel/v6.x/patch-6.7.xz")!
        case .redis:
            URL(string: "https://github.com/redis/redis/compare/7.0.0...7.2.0.diff")!
        case .swiftArgumentParser:
            URL(string: "https://github.com/apple/swift-argument-parser/compare/1.0.0...1.5.0.diff")!
        }
    }

    var remoteIsXZCompressed: Bool {
        self == .linuxKernel
    }
}

struct FixtureError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Materializes fixtures as uncompressed diff files on disk from a cached
/// download, fetching from the canonical remote URL on a cache miss.
enum RealWorldFixtureStore {
    static let cacheDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("git-diff-parser-tests", isDirectory: true)

    static func localDiffURL(for fixture: RealWorldFixture) async throws -> URL {
        let cached = cacheDirectory.appendingPathComponent(fixture.rawValue + ".diff")
        if FileManager.default.fileExists(atPath: cached.path) {
            // A crashed earlier run or a failed download must not poison
            // every subsequent run: re-validate before trusting the cache.
            if let head = try? FileHandle(forReadingFrom: cached).read(upToCount: 4096),
               looksLikeDiff(head) {
                return cached
            }
            try? FileManager.default.removeItem(at: cached)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let raw = try await download(fixture.remoteURL)
        let diff = fixture.remoteIsXZCompressed ? try decompressXZ(raw) : raw
        try validate(diff, from: fixture.remoteURL.absoluteString)
        try diff.write(to: cached, options: .atomic)
        return cached
    }

    private static func looksLikeDiff(_ head: Data?) -> Bool {
        guard let head, !head.isEmpty else { return false }
        return head.contains(Data("diff --git".utf8))
    }

    /// Refuses to cache a payload that is not actually a diff (error pages,
    /// truncated downloads), with a hint for manual remediation.
    private static func validate(_ diff: Data, from source: String) throws {
        guard looksLikeDiff(diff.prefix(4096)) else {
            throw FixtureError("""
                payload from \(source) does not look like a unified diff; \
                if a corrupt file was cached, delete \(cacheDirectory.path) and re-run
                """)
        }
    }

    private static func decompressXZ(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzma) as Data
    }

    private static func download(_ url: URL) async throws -> Data {
        var lastError: (any Error)?
        for attempt in 1...3 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, !data.isEmpty else {
                    throw FixtureError("GET \(url) returned status \(status)")
                }
                return data
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        throw FixtureError("failed to download \(url): \(lastError.map(String.init(describing:)) ?? "unknown error")")
    }
}

/// Independent oracle: per-file added-line counts as computed by git's own
/// patch parser, `git apply --numstat`.
enum GitNumstat {
    static func addedLineCounts(forDiffAt url: URL) throws -> [String: Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "apply", "--numstat", url.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        // Drain before waiting, or a full pipe buffer deadlocks the child.
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError("git apply --numstat exited with \(process.terminationStatus)")
        }

        var counts: [String: Int] = [:]
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            // Binary files report "-" for the added count and fail Int().
            guard fields.count == 3, let added = Int(fields[0]), added > 0 else { continue }
            counts[normalize(String(fields[2])), default: 0] += added
        }
        return counts
    }

    /// Unlike `git diff --numstat -M`, `git apply --numstat` always prints
    /// the plain new-side path for renames (verified empirically), so the
    /// only normalization needed is undoing git's C-style path quoting.
    private static func normalize(_ rawPath: String) -> String {
        rawPath.hasPrefix("\"") ? DiffParser.unquote(rawPath) : rawPath
    }
}
