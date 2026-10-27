@testable import Dangerfile
import StewardTesting
import Testing

@Suite("No dependencies")
struct NoDependenciesTests {
    @Test("a dependency added to the library's manifest is a failure at its line")
    func dependency() async throws {
        let context = try Context.fixture(diff: SampleDiff.dependency)
        let findings = try await Checks.noDependencies.evaluate(context)
        #expect(findings.map(\.kind) == [.failure])
        #expect(findings.map(\.location) == [Location(path: "Package.swift", line: 4)])
    }

    @Test("other manifest edits, and the Dangerfile's own dependencies, pass")
    func otherEdits() async throws {
        let context = try Context.fixture(diff: SampleDiff.otherManifestEdits)
        #expect(try await Checks.noDependencies.evaluate(context).isEmpty)
    }

    @Test("a pull request that leaves the manifest alone passes")
    func noManifest() async throws {
        let context = try Context.fixture(diff: SampleDiff.source)
        #expect(try await Checks.noDependencies.evaluate(context).isEmpty)
    }
}
