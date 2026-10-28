import Testing
@testable import GitDiffKit

/// Compares real pull requests with GitHub's own counts: each one's diff,
/// as the summary reads it, against GitHub's list of its files.
///
/// Off by default, and one pull request at a time, as GitHub asks of API
/// clients. `GIT_DIFF_PARSER_GITHUB_ORACLE` turns it on, and `GITHUB_TOKEN`
/// lifts GitHub's rate limit for the first run; later ones read the cache.
@Suite(
    "GitHub's per-file counts for real pull requests", .serialized,
    .enabled(if: GitHubPullRequests.isEnabled)
)
struct GitHubPullRequestTests {
    @Test(
        "every pull request's per-file counts match GitHub's, and its model renders back",
        arguments: GitHubPullRequests.all
    )
    func matchesGitHub(pullRequest: String) async throws {
        let bytes = try await GitHubPullRequests.diff(of: pullRequest)
        let summary = DiffSummary.of(bytes)
        // GitHub counts a binary file's lines as zero.
        let ours = GitApply.numstat(of: summary.files).map { entry in
            GitApply.NumstatEntry(added: entry.added ?? 0, deleted: entry.deleted ?? 0, path: entry.path)
        }
        let github = try await GitHubPullRequests.files(of: pullRequest).map { file in
            GitApply.NumstatEntry(added: file.additions, deleted: file.deletions, path: Array(file.filename.utf8))
        }
        let byPath = { (entries: [GitApply.NumstatEntry]) in
            entries.sorted { $0.path.lexicographicallyPrecedes($1.path) }
        }
        Oracle.expectEqualEntries(byPath(ours), byPath(github))
        let diff = Diff.of(bytes)
        #expect(summary.damage.isEmpty && diff.damage.isEmpty, "\(summary.damage)")
        #expect([UInt8](rendering: diff) == bytes, "the model doesn't render back")
        let counts = OracleSweep.tally(diff).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        print("github \(pullRequest): bytes=\(bytes.count) \(counts.joined(separator: " "))")
    }
}
