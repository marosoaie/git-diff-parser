@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Value types")
struct ValueTypesTests {
    @Test("a class or an actor added to the library's sources is a warning at each, and other types pass")
    func referenceTypes() async throws {
        let added = SampleDiff.adding("Sources/GitDiffKit/Cache.swift", """
            final class Cache {}
            actor Queue {}
            struct Diff {}
            enum Kind {}
            protocol Parsing {}

            """)
        let context = try Context.fixture(diff: added.diff, files: added.files)
        let cache = { (line: Int) in Location(path: "Sources/GitDiffKit/Cache.swift", line: line) }
        #expect(try await Checks.valueTypes.evaluate(context) == [
            .warning("`Cache` isn't a value type (AGENTS.md).", at: cache(1)),
            .warning("`Queue` isn't a value type (AGENTS.md).", at: cache(2)),
        ])
    }

    @Test("a class in the tests isn't the rule's")
    func tests() async throws {
        let added = SampleDiff.adding("Tests/GitDiffKitTests/Box.swift", "final class Box {}\n")
        let context = try Context.fixture(diff: added.diff, files: added.files)
        #expect(try await Checks.valueTypes.evaluate(context).isEmpty)
    }

    @Test("a class the pull request leaves alone isn't reported when it edits the file")
    func untouched() async throws {
        let context = try Context.fixture(
            diff: """
                diff --git a/Sources/GitDiffKit/Legacy.swift b/Sources/GitDiffKit/Legacy.swift
                index 1111111..2222222 100644
                --- a/Sources/GitDiffKit/Legacy.swift
                +++ b/Sources/GitDiffKit/Legacy.swift
                @@ -1,2 +1,3 @@
                 final class Legacy {}
                 struct Diff {}
                +struct Hunk {}

                """,
            files: ["Sources/GitDiffKit/Legacy.swift": """
                final class Legacy {}
                struct Diff {}
                struct Hunk {}

                """]
        )
        #expect(try await Checks.valueTypes.evaluate(context).isEmpty)
    }
}
