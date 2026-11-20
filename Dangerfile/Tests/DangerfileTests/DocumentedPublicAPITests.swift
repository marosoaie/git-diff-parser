@testable import Dangerfile
import StewardTesting
import Testing

@Suite("Documented public API")
struct DocumentedPublicAPITests {
    @Test("each public type, function or member without a doc comment is a warning, in line order")
    func undocumented() async throws {
        let added = SampleDiff.adding("Sources/GitDiffKit/Hunk.swift", """
            /// A hunk.
            public struct Hunk {
                public let header: String
                /// The lines.
                public var lines: [String]
                /// Makes a hunk.
                public init(header: String, lines: [String]) {
                    self.header = header
                    self.lines = lines
                }
                func render() -> String { header }
                public func summary() -> String { header }
            }
            public enum Side {
                /// The old side.
                case old
                case new
            }

            """)
        let context = try Context.fixture(diff: added.diff, files: added.files)
        #expect(try await Checks.documentedPublicAPI.evaluate(context) == [
            .warning("Public `header` has no doc comment (AGENTS.md).", at: Self.hunk(line: 3)),
            .warning("Public `summary` has no doc comment (AGENTS.md).", at: Self.hunk(line: 12)),
            .warning("Public `Side` has no doc comment (AGENTS.md).", at: Self.hunk(line: 14)),
            .warning("Public `new` has no doc comment (AGENTS.md).", at: Self.hunk(line: 17)),
        ])
    }

    @Test("a public protocol's requirements and a public extension's members are public")
    func implicitlyPublic() async throws {
        let added = SampleDiff.adding("Sources/GitDiffKit/Parsing.swift", """
            /// Parses.
            public protocol Parsing {
                func parse()
                var name: String { get }
            }
            public extension Parsing {
                func render() -> String { name }
            }

            """)
        let context = try Context.fixture(diff: added.diff, files: added.files)
        #expect(try await Checks.documentedPublicAPI.evaluate(context).map(\.location?.line) == [3, 4, 7])
    }

    @Test("removing a declaration's doc comment reports it, and one the pull request leaves alone isn't")
    func scope() async throws {
        let context = try Context.fixture(
            diff: """
                diff --git a/Sources/GitDiffKit/Diff.swift b/Sources/GitDiffKit/Diff.swift
                index 1111111..2222222 100644
                --- a/Sources/GitDiffKit/Diff.swift
                +++ b/Sources/GitDiffKit/Diff.swift
                @@ -1,3 +1,2 @@
                 public struct Legacy {}
                -/// A diff.
                 public struct Diff {}

                """,
            files: ["Sources/GitDiffKit/Diff.swift": """
                public struct Legacy {}
                public struct Diff {}

                """]
        )
        #expect(try await Checks.documentedPublicAPI.evaluate(context) == [
            .warning(
                "Public `Diff` has no doc comment (AGENTS.md).",
                at: Location(path: "Sources/GitDiffKit/Diff.swift", line: 2)
            ),
        ])
    }

    @Test("an undocumented public function in the tests isn't the rule's")
    func tests() async throws {
        let added = SampleDiff.adding("Tests/GitDiffKitTests/Support.swift", "public func fixture() {}\n")
        let context = try Context.fixture(diff: added.diff, files: added.files)
        #expect(try await Checks.documentedPublicAPI.evaluate(context).isEmpty)
    }

    static func hunk(line: Int) -> Location {
        Location(path: "Sources/GitDiffKit/Hunk.swift", line: line)
    }
}
