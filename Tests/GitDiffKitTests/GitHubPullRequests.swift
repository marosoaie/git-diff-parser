import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The opt-in comparison with GitHub: real pull requests of public
/// repositories, each one's diff as GitHub serves it, and GitHub's own
/// per-file counts for it.
///
/// Both come from the REST API and are cached for good, since a merged
/// pull request's diff doesn't change. The API's limits shape the list:
/// - The diff is refused, `406 too_large`, for a pull request of more than
///   300 files, and for some of more than 20,000 lines; others far larger
///   are served. None of the listed pull requests is refused.
/// - The file list stops at 3,000 files, which no servable diff reaches.
/// - The file list leaves out the patch of a large file, but never its
///   counts, the only part read here.
enum GitHubPullRequests {
    /// Whether `GIT_DIFF_PARSER_GITHUB_ORACLE` is set.
    static let isEnabled = ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_GITHUB_ORACLE"] != nil

    /// `GITHUB_TOKEN`, without which GitHub allows 60 requests an hour.
    private static let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]

    /// The pull requests compared, as `owner/repository#number`: seven of
    /// each of the first repositories, merged in September 2026; the
    /// largest found that GitHub still serves (to 265 files, or 254,275
    /// lines in 13); and, as those have none, some with binary files, mode
    /// changes, submodules, and symlinks.
    static let all = [
        ("swiftlang/swift", [92738, 92739, 92741, 92749, 92751, 92752, 92758]),
        ("apple/swift-nio", [3739, 3740, 3741, 3742, 3750, 3751, 3755]),
        ("microsoft/vscode", [335333, 338984, 338988, 338993, 338995, 338996, 338998, 339009]),
        ("vercel/next.js", [99476, 99477, 99478, 99479, 99480, 99481, 99482]),
        ("rust-lang/rust", [163472, 163498, 163500, 163502, 163505, 163507, 163522, 163526, 164216, 164928]),
        ("python/cpython", [158515, 158517, 158519, 158520, 158528, 158531, 158538]),
        ("nodejs/node", [66368, 66372, 66373, 66377, 66383, 66401, 66416]),
        ("dotnet/runtime", [134876, 134877, 134882, 134886, 134914, 134918, 134924, 135318]),
        ("microsoft/PowerToys", [50885, 50889, 50891, 50893, 50917, 50921, 50923, 51396]),
        ("Homebrew/homebrew-core", [314580, 314581, 314582, 314584, 314585, 314590, 314591]),
        ("flutter/flutter", [193572, 193577, 193578, 193581, 193582, 193584, 193594]),
        ("kubernetes/kubernetes", [142532, 142535, 142536, 142537, 142552, 142556, 142576, 142604, 142834]),
        ("microsoft/TypeScript", [64117, 64457, 64620]),
        ("microsoft/fluentui-system-icons", [1257]),
        ("microsoft/WSL", [41715]),
        ("google/site-kit-wp", [13095]),
        ("flutter/website", [13724]),
        ("nlohmann/json_test_data", [7]),
        ("locationtech/geotrellis", [3622]),
        ("centreon/centreon-plugins", [6456]),
        ("duckdb/duckdb-iceberg", [1426]),
        ("commaai/openpilot", [38996]),
        ("redhat-cop/gitops-catalog", [439]),
        ("gemwalletcom/wallet", [1414]),
    ].flatMap { repository, numbers in numbers.map { "\(repository)#\($0)" } }

    /// One file of GitHub's list for a pull request.
    struct File: Codable {
        /// The file's path, its new one if it was renamed.
        var filename: String
        /// Zero for a binary file, like `deletions`.
        var additions: Int
        var deletions: Int
    }

    /// The pull request's diff, as GitHub serves it.
    static func diff(of pullRequest: String) async throws -> [UInt8] {
        Array(try await cached(pullRequest, as: "diff") {
            try await get(pullRequest, query: "", accept: "application/vnd.github.diff")
        })
    }

    /// GitHub's list of the pull request's files.
    static func files(of pullRequest: String) async throws -> [File] {
        try JSONDecoder().decode([File].self, from: try await cached(pullRequest, as: "json") {
            var files: [File] = []
            // A cursor rather than a map: GitHub doesn't say how many pages
            // there are, so the list ends at the first short one.
            for page in 1... {
                let batch = try JSONDecoder().decode(
                    [File].self,
                    from: try await get(
                        pullRequest, query: "/files?per_page=100&page=\(page)", accept: "application/vnd.github+json"
                    )
                )
                files += batch
                if batch.count < 100 { break }
            }
            return try JSONEncoder().encode(files)
        })
    }

    /// What `fetch` returns, kept in the fixture cache under the pull
    /// request's repository and number.
    private static func cached(
        _ pullRequest: String, as pathExtension: String, fetch: () async throws -> Data
    ) async throws -> Data {
        let (repository, number) = parts(of: pullRequest)
        let url = RealWorldFixtureStore.cacheDirectory
            .appendingPathComponent("github-pull-requests", isDirectory: true)
            .appendingPathComponent(String(repository), isDirectory: true)
            .appendingPathComponent("\(number).\(pathExtension)")
        if let data = try? Data(contentsOf: url) {
            return data
        }
        let data = try await fetch()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }

    private static func get(_ pullRequest: String, query: String, accept: String) async throws -> Data {
        let (repository, number) = parts(of: pullRequest)
        let url = URL(string: "https://api.github.com/repos/\(repository)/pulls/\(number)\(query)")!
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("git-diff-parser-tests", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await RealWorldFixtureStore.download(request)
    }

    private static func parts(of pullRequest: String) -> (repository: Substring, number: Substring) {
        let parts = pullRequest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        return (parts[0], parts.last ?? "")
    }
}
