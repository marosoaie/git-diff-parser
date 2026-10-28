@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Third-party notices")
struct ThirdPartyNoticesTests {
    @Test("a new notice file without an entry in the list gets a warning at the file")
    func unlisted() async throws {
        let context = try Context.fixture(diff: SampleDiff.fixtureWithNotice)
        let findings = try await Checks.thirdPartyNotices.evaluate(context)
        #expect(findings.map(\.kind) == [.warning])
        #expect(findings.map(\.location) == [Location(path: "Tests/Fixtures/NOTICE")])
    }

    @Test("an entry in the list clears it")
    func listed() async throws {
        let context = try Context.fixture(diff: SampleDiff.fixtureWithNoticeListed)
        #expect(try await Checks.thirdPartyNotices.evaluate(context).isEmpty)
    }

    @Test(
        "licences and notices are known by their usual names",
        arguments: ["LICENSE", "Specs/github/LICENSE", "LICENCE.md", "a/COPYING", "a/NOTICE.txt", "a/license"]
    )
    func licenceNames(path: String) {
        #expect(Checks.isLicence(path))
    }

    @Test("other files aren't licences", arguments: ["Sources/Licensing.swift", "THIRD_PARTY_NOTICES.md", "README.md"])
    func otherNames(path: String) {
        #expect(!Checks.isLicence(path))
    }
}
