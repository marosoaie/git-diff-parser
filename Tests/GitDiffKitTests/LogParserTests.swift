import Testing
@testable import BuildLogKit
@testable import DiffDiagnostics
@testable import GitDiffKit

@Suite("LogParser")
struct LogParserTests {
    @Test("parses clang/swiftc/SwiftLint style diagnostics out of noisy logs")
    func parsesDiagnostics() {
        let log = """
        Compiling Swift Module 'App' (3 sources)
        /repo/Sources/App/Foo.swift:42:13: warning: variable 'x' was never used; consider replacing with '_'
        /repo/Sources/App/Foo.swift:50: error: missing return in function
        note: this line has no path so it is ignored
        Linting 'Bar.swift' (1/3)
        /repo/Sources/App/Bar.swift:7:1: warning: Line should be 120 characters or less (line_length)
        /repo/Sources/App/Baz.swift:9:5: remark: something informational
        """
        let diagnostics = ClangStyleLogParser.diagnostics(in: log)
        #expect(diagnostics == [
            Diagnostic(
                path: "/repo/Sources/App/Foo.swift", line: 42, column: 13,
                severity: .warning,
                message: "variable 'x' was never used; consider replacing with '_'"
            ),
            Diagnostic(
                path: "/repo/Sources/App/Foo.swift", line: 50, column: nil,
                severity: .error, message: "missing return in function"
            ),
            Diagnostic(
                path: "/repo/Sources/App/Bar.swift", line: 7, column: 1,
                severity: .warning,
                message: "Line should be 120 characters or less (line_length)"
            ),
            Diagnostic(
                path: "/repo/Sources/App/Baz.swift", line: 9, column: 5,
                severity: .note, message: "something informational"
            ),
        ])
    }

    @Test("collapses duplicate diagnostics (multi-target builds)")
    func deduplicates() {
        let log = """
        /repo/A.swift:1:1: warning: dup
        /repo/A.swift:1:1: warning: dup
        /repo/A.swift:1:1: warning: not a dup, different message
        """
        #expect(ClangStyleLogParser.diagnostics(in: log).count == 2)
    }

    @Test("paths containing spaces are kept intact")
    func pathsWithSpaces() {
        let log = "/repo/My App/View Models/Foo.swift:3:1: error: boom"
        let diagnostics = ClangStyleLogParser.diagnostics(in: log)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].path == "/repo/My App/View Models/Foo.swift")
        #expect(diagnostics[0].severity == .error)
    }
}

@Suite("DiagnosticMatcher")
struct DiagnosticMatcherTests {
    let changes = ChangedLines(files: [
        "Sources/App/Foo.swift": [10, 11, 12],
        "Foo.swift": [1],
        "Sources/App/Bar.swift": [5],
    ])

    @Test("absolute log paths match repo-relative diff paths by suffix")
    func suffixMatching() {
        let diagnostics = [
            Diagnostic(path: "/ci/checkout/Sources/App/Foo.swift", line: 11, severity: .warning, message: "on changed line"),
            Diagnostic(path: "/ci/checkout/Sources/App/Foo.swift", line: 99, severity: .warning, message: "elsewhere"),
            Diagnostic(path: "/ci/checkout/Sources/App/Other.swift", line: 11, severity: .warning, message: "untouched file"),
        ]
        let matched = DiagnosticMatcher.match(diagnostics, against: changes)
        #expect(matched.map(\.message) == ["on changed line"])
        #expect(matched[0].path == "Sources/App/Foo.swift")
    }

    @Test("the longest suffix wins over shorter ambiguous ones")
    func longestSuffixWins() {
        let diagnostics = [
            Diagnostic(path: "/ci/Sources/App/Foo.swift", line: 10, severity: .warning, message: "m")
        ]
        let matched = DiagnosticMatcher.match(diagnostics, against: changes)
        // Must resolve to Sources/App/Foo.swift (line 10 changed), not the
        // top-level Foo.swift (where only line 1 changed).
        #expect(matched.count == 1)
        #expect(matched[0].path == "Sources/App/Foo.swift")
    }

    @Test("suffix matching is component-aligned, not substring based")
    func componentAligned() {
        let changes = ChangedLines(files: ["Bar.swift": [5]])
        let diagnostics = [
            Diagnostic(path: "/ci/FooBar.swift", line: 5, severity: .warning, message: "m")
        ]
        #expect(DiagnosticMatcher.match(diagnostics, against: changes).isEmpty)
    }

    @Test("explicit repo root strips the prefix before matching")
    func repoRoot() {
        let diagnostics = [
            Diagnostic(path: "/ci/checkout/Sources/App/Bar.swift", line: 5, severity: .error, message: "m")
        ]
        let matched = DiagnosticMatcher.match(
            diagnostics, against: changes, repoRoot: "/ci/checkout"
        )
        #expect(matched.count == 1)
        #expect(matched[0].path == "Sources/App/Bar.swift")
    }

    @Test("tolerance widens line matching")
    func tolerance() {
        let diagnostics = [
            Diagnostic(path: "Sources/App/Bar.swift", line: 7, severity: .warning, message: "near")
        ]
        #expect(DiagnosticMatcher.match(diagnostics, against: changes).isEmpty)
        let matched = DiagnosticMatcher.match(
            diagnostics, against: changes, tolerance: 2)
        #expect(matched.map(\.message) == ["near"])
    }

    @Test("output is sorted by file, line, column")
    func sortedOutput() {
        let diagnostics = [
            Diagnostic(path: "Sources/App/Foo.swift", line: 12, severity: .warning, message: "b"),
            Diagnostic(path: "Sources/App/Bar.swift", line: 5, severity: .warning, message: "a"),
            Diagnostic(path: "Sources/App/Foo.swift", line: 10, severity: .warning, message: "c"),
        ]
        let matched = DiagnosticMatcher.match(diagnostics, against: changes)
        #expect(matched.map(\.message) == ["a", "c", "b"])
    }
}
