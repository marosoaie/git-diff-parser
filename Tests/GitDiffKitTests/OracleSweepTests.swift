import Foundation
import Testing
@testable import GitDiffKit

/// Compares every commit of local clones with git's own counts: each
/// commit's `git show` output, as the summary reads it, against
/// `git show --numstat`, merges against their first parent.
///
/// Off by default. `GIT_DIFF_PARSER_SWEEP_CLONES` lists the clones,
/// separated by colons, and `GIT_DIFF_PARSER_SWEEP_MAX_COMMITS` caps each
/// at its newest commits; docs/validation.md names the clones last swept
/// and how to make them. Each clone's commits are split across
/// `OracleSweep.shards`, and every case prints what its commits held.
@Suite("git show --numstat sweep over local clones", .enabled(if: OracleSweep.clones != nil))
struct OracleSweepTests {
    @Test(
        "every commit's per-file counts match git show --numstat, and its model renders back",
        arguments: OracleSweep.clones ?? [], OracleSweep.shards
    )
    func matchesGitShow(clone: String, shard: Int) throws {
        let commits = try OracleSweep.commits(in: clone).enumerated()
            .filter { $0.offset % OracleSweep.shards.count == shard }
            .map(\.element)
        var tally: [String: Int] = [:]
        var largest = 0
        var mismatches: [String] = []
        try commits.forEach { commit in
            let bytes = try OracleSweep.patch(of: commit, in: clone)
            let summary = DiffSummary.of(bytes)
            let ours = GitApply.numstat(of: summary.files)
            let oracle = OracleSweep.entries(try OracleSweep.numstat(of: commit, in: clone), asTextReads: summary.files)
            let diff = Diff.of(bytes)
            let rendersBack = [UInt8](rendering: diff) == bytes
            guard ours == oracle, summary.damage.isEmpty, diff.damage.isEmpty, rendersBack else {
                if mismatches.count < 5 {
                    Oracle.expectEqualEntries(ours, oracle)
                    #expect(summary.damage.isEmpty && diff.damage.isEmpty, "\(commit): \(summary.damage)")
                    #expect(rendersBack, "\(commit) doesn't render back")
                }
                mismatches.append(commit)
                return
            }
            tally.merge(OracleSweep.tally(diff), uniquingKeysWith: +)
            largest = max(largest, bytes.count)
        }
        #expect(
            mismatches.isEmpty, "\(mismatches.count) of \(commits.count) commits disagree: \(mismatches.prefix(20))"
        )
        let counts = tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("""
            sweep \(URL(fileURLWithPath: clone).lastPathComponent) shard \(shard): commits=\(commits.count) \
            mismatches=\(mismatches.count) largest=\(largest) \(counts)
            """)
    }
}
