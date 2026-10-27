@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Diagnostics on changed lines")
struct DiagnosticsTests {
    /// A build log with a warning on the line `SampleDiff.source` adds and
    /// one on a line it leaves alone.
    static let buildLog = """
        /ci/git-diff-parser/Sources/GitDiffKit/Diff.swift:2:5: warning: initialization of immutable value 'unused' \
        was never used
        /ci/git-diff-parser/Sources/GitDiffKit/Diff.swift:3:15: warning: never reported
        """

    /// A SwiftLint log, in its default reporter's format, with a violation
    /// on the added line.
    static let swiftLintLog = """
        /ci/git-diff-parser/Sources/GitDiffKit/Diff.swift:2:1: warning: Line Length Violation: Line should be 120 \
        characters or less (line_length)
        """

    @Test("a warning on a changed line, in either log, is a failure")
    func warnings() async throws {
        let workspace = try ReportWorkspace(logs: ["build.log": Self.buildLog, "swiftlint.log": Self.swiftLintLog])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.source, workspace: workspace.path)
        let findings = try await Checks.diagnostics.evaluate(context)
        let location = Location(path: "Sources/GitDiffKit/Diff.swift", line: 2)
        #expect(findings.map(\.kind) == [.failure, .failure])
        #expect(findings.map(\.location) == [location, location])
    }

    @Test("clean logs give no findings")
    func clean() async throws {
        let workspace = try ReportWorkspace(logs: ["build.log": "Build complete!\n", "swiftlint.log": ""])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.source, workspace: workspace.path)
        #expect(try await Checks.diagnostics.evaluate(context).isEmpty)
    }

    @Test("a missing log is a failure, so a job that stops writing one can't pass unnoticed")
    func missingLog() async throws {
        let workspace = try ReportWorkspace(logs: ["build.log": "Build complete!\n"])
        defer { workspace.remove() }
        let context = try Context.fixture(diff: SampleDiff.source, workspace: workspace.path)
        let findings = try await Checks.diagnostics.evaluate(context)
        #expect(findings.map(\.kind) == [.failure])
        #expect(findings.first?.text.contains("`swiftlint.log`") == true)
    }
}
