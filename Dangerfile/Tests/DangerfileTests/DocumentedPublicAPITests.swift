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

    @Test("in a file the pull request changes, each undocumented public declaration is reported, changed or not")
    func scope() async throws {
        let context = try Context.fixture(
            diff: """
                diff --git a/Sources/GitDiffKit/Diff.swift b/Sources/GitDiffKit/Diff.swift
                index 1111111..2222222 100644
                --- a/Sources/GitDiffKit/Diff.swift
                +++ b/Sources/GitDiffKit/Diff.swift
                @@ -2,5 +2,4 @@
                 public struct Legacy {
                     public var count = 0
                 }
                -/// A diff.
                 public struct Diff {}

                """,
            files: ["Sources/GitDiffKit/Diff.swift": """
                /// Old.
                public struct Legacy {
                    public var count = 0
                }
                public struct Diff {}

                """]
        )
        #expect(try await Checks.documentedPublicAPI.evaluate(context) == [
            .warning(
                "Public `count` has no doc comment (AGENTS.md).",
                at: Location(path: "Sources/GitDiffKit/Diff.swift", line: 3)
            ),
            .warning(
                "Public `Diff` has no doc comment (AGENTS.md).",
                at: Location(path: "Sources/GitDiffKit/Diff.swift", line: 5)
            ),
        ])
    }

    @Test("making a protocol and an extension public reports the undocumented members that exposes")
    func madePublic() async throws {
        let context = try Context.fixture(
            diff: """
                diff --git a/Sources/GitDiffKit/Parsing.swift b/Sources/GitDiffKit/Parsing.swift
                index 1111111..2222222 100644
                --- a/Sources/GitDiffKit/Parsing.swift
                +++ b/Sources/GitDiffKit/Parsing.swift
                @@ -1,7 +1,7 @@
                 /// Parses.
                -protocol Parsing {
                +public protocol Parsing {
                     func parse()
                 }
                -extension Parsing {
                +public extension Parsing {
                     func render() {}
                 }

                """,
            files: ["Sources/GitDiffKit/Parsing.swift": """
                /// Parses.
                public protocol Parsing {
                    func parse()
                }
                public extension Parsing {
                    func render() {}
                }

                """]
        )
        #expect(try await Checks.documentedPublicAPI.evaluate(context).map(\.location?.line) == [3, 6])
    }

    @Test("making a type public reports what that exposes inside it, at any depth")
    func madePublicNested() async throws {
        let context = try Context.fixture(
            diff: """
                diff --git a/Sources/GitDiffKit/Outer.swift b/Sources/GitDiffKit/Outer.swift
                index 1111111..2222222 100644
                --- a/Sources/GitDiffKit/Outer.swift
                +++ b/Sources/GitDiffKit/Outer.swift
                @@ -1,6 +1,6 @@
                 /// Outer.
                -struct Outer {
                +public struct Outer {
                     public struct Inner {
                         public var count = 0
                     }
                 }

                """,
            files: ["Sources/GitDiffKit/Outer.swift": """
                /// Outer.
                public struct Outer {
                    public struct Inner {
                        public var count = 0
                    }
                }

                """]
        )
        #expect(try await Checks.documentedPublicAPI.evaluate(context).map(\.location?.line) == [3, 4])
    }

    @Test("a declaration that says public inside a type that isn't isn't public API")
    func enclosingAccess() async throws {
        let added = SampleDiff.adding("Sources/GitDiffKit/Cache.swift", """
            struct Index { public func reset() {} }
            struct Cache {
                public func reset() {}
                public struct Entry {
                    public var key = ""
                }
            }
            /// A diff.
            public struct Diff {
                struct Storage {
                    public var count = 0
                }
            }

            """)
        let context = try Context.fixture(diff: added.diff, files: added.files)
        #expect(try await Checks.documentedPublicAPI.evaluate(context).isEmpty)
    }

    @Test("a public global let, var, typealias or macro without a doc comment is a warning")
    func globals() async throws {
        let added = SampleDiff.adding("Sources/GitDiffKit/Defaults.swift", """
            public let contextLines = 3
            /// The longest line.
            public let maximumLineLength = 4096
            public var isVerbose = false
            public typealias LineNumber = Int
            /// A path in the repository.
            public typealias Path = String
            let hidden = 0
            typealias Hidden = Int
            public macro Stringify<T>(_ value: T) -> (T, String) = #externalMacro(module: "M", type: "T")

            """)
        let context = try Context.fixture(diff: added.diff, files: added.files)
        #expect(try await Checks.documentedPublicAPI.evaluate(context) == [
            .warning("Public `contextLines` has no doc comment (AGENTS.md).", at: Self.defaults(line: 1)),
            .warning("Public `isVerbose` has no doc comment (AGENTS.md).", at: Self.defaults(line: 4)),
            .warning("Public `LineNumber` has no doc comment (AGENTS.md).", at: Self.defaults(line: 5)),
            .warning("Public `Stringify` has no doc comment (AGENTS.md).", at: Self.defaults(line: 10)),
        ])
    }

    @Test("a public member of an extension is public, though the type extended isn't, as it may be in another file")
    func extensionMember() async throws {
        let added = SampleDiff.adding("Sources/GitDiffKit/Index.swift", """
            struct Index {}
            extension Index {
                public var count: Int { 0 }
            }

            """)
        let context = try Context.fixture(diff: added.diff, files: added.files)
        #expect(try await Checks.documentedPublicAPI.evaluate(context).map(\.location?.line) == [3])
    }

    @Test("a deinit and a freestanding macro in a public type aren't symbols")
    func notSymbols() async throws {
        let added = SampleDiff.adding("Sources/GitDiffKit/Handle.swift", """
            /// A handle.
            public struct Handle: ~Copyable {
                deinit {}
            }
            /// A diff.
            public struct Diff {}
            public extension Diff {
                #warning("later")
            }

            """)
        let context = try Context.fixture(diff: added.diff, files: added.files)
        #expect(try await Checks.documentedPublicAPI.evaluate(context).isEmpty)
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

    static func defaults(line: Int) -> Location {
        Location(path: "Sources/GitDiffKit/Defaults.swift", line: line)
    }
}
