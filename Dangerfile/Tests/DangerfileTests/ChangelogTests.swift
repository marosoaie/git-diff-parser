@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Changelog")
struct ChangelogTests {
    static let missing = Finding.warning("""
        Add an entry to CHANGELOG.md, under Unreleased, for the changes under `Sources/`.
        """)

    @Test("a change under Sources without a changelog entry gets a warning")
    func missing() async throws {
        let context = try Context.fixture(diff: SampleDiff.source)
        #expect(try await Checks.changelog.evaluate(context) == [Self.missing])
    }

    @Test("a changelog entry clears it")
    func entry() async throws {
        let context = try Context.fixture(diff: SampleDiff.sourceWithChangelog)
        #expect(try await Checks.changelog.evaluate(context).isEmpty)
    }

    @Test("deleting the changelog isn't an entry")
    func deletedChangelog() async throws {
        let context = try Context.fixture(diff: SampleDiff.sourceDeletingChangelog)
        #expect(try await Checks.changelog.evaluate(context) == [Self.missing])
    }

    @Test("moving a file out of Sources is a change to them")
    func moveOutOfSources() async throws {
        let context = try Context.fixture(diff: SampleDiff.moveOutOfSources)
        #expect(try await Checks.changelog.evaluate(context) == [Self.missing])
    }

    @Test("a change outside Sources needs no entry")
    func outsideSources() async throws {
        let context = try Context.fixture(diff: SampleDiff.readme)
        #expect(try await Checks.changelog.evaluate(context).isEmpty)
    }
}
