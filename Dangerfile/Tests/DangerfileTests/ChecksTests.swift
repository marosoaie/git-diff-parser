@testable import Dangerfile
import StewardTesting
import Testing

/// Every rule at once, as ci.yml's run checks a pull request, against a
/// fake host that records what the run posts.
@Suite("Checks")
struct ChecksTests {
    @Test("a warning on a changed line fails the run, and the summary is posted")
    func failing() async throws {
        let workspace = try ReportWorkspace(logs: [
            "build.log": DiagnosticsTests.buildLog,
            "swiftlint.log": "",
        ])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.sourceWithChangelog, workspace: workspace.path)
        let host = FakePullRequestHost(pullRequest: context.pullRequest)
        let outcome = await Checks.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 1)
        #expect(outcome.report?.findings.map(\.rule) == ["Diagnostics on changed lines"])
        #expect(await host.comments.map(\.body) == [outcome.summary])
    }

    @Test("clean logs and a change with its changelog entry pass, and nothing is posted")
    func passing() async throws {
        let workspace = try ReportWorkspace(logs: ["build.log": "Build complete!\n", "swiftlint.log": ""])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.sourceWithChangelog, workspace: workspace.path)
        let host = FakePullRequestHost(pullRequest: context.pullRequest)
        let outcome = await Checks.run(on: context, postingTo: host)
        #expect(outcome.exitStatus == 0)
        #expect(outcome.report?.findings == [])
        #expect(await host.comments.isEmpty)
    }
}
