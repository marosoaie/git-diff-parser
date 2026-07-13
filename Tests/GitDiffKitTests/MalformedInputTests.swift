import Testing
@testable import BuildLogKit
@testable import GitDiffKit

/// Regression tests for hostile or malformed input: none of these may crash,
/// and recoverable damage must stay contained to the malformed file.
@Suite("Malformed input")
struct MalformedInputTests {
    @Test("a bare '+++ ' header with an empty payload does not crash")
    func emptyFileHeaderPayload() {
        // The +++ line ends in a lone space (\u{20} keeps it lint-visible).
        let diff = """
            diff --git a/x b/x
            --- a/x
            +++\u{20}
            @@ -0,0 +1 @@
            +z

            """
        // No usable path, so the added line has nowhere to be recorded.
        #expect(ChangedLines(diff: diff).isEmpty)
        #expect(DiffParser.parseFileHeaderPath("") == nil)
        #expect(DiffParser.parseFileHeaderPath("\t2024-01-01") == nil)
    }

    @Test("a diff truncated mid-hunk neither invents lines nor loses the next file")
    func truncatedHunk() {
        // The first hunk declares 5 lines per side but is cut off after two.
        let diff = """
            diff --git a/A.swift b/A.swift
            --- a/A.swift
            +++ b/A.swift
            @@ -1,5 +1,5 @@
             ctx
            +added
            diff --git a/B.swift b/B.swift
            --- a/B.swift
            +++ b/B.swift
            @@ -1 +1,2 @@
             x
            +y

            """
        #expect(ChangedLines(diff: diff).lineSets == [
            "A.swift": [2],
            "B.swift": [2],
        ])
    }

    @Test("absurd numbers in a hunk header reject the header instead of trapping")
    func hunkHeaderOverflow() {
        let header = "@@ -99999999999999999999999999,1 +1,1 @@"
        #expect(DiffParser.parseHunkHeader(ArraySlice(header.utf8)) == nil)
        // And a whole parse containing such a header must not trap either.
        let diff = """
            diff --git a/x b/x
            --- a/x
            +++ b/x
            \(header)
            +z

            """
        #expect(ChangedLines(diff: diff).isEmpty)
    }

    @Test("extreme tolerances never overflow")
    func extremeTolerance() {
        let ranges = LineRangeSet([5...7])
        #expect(ranges.contains(1, tolerance: Int.max))
        #expect(ranges.contains(Int.max - 1, tolerance: Int.max))
        #expect(!ranges.contains(9, tolerance: -5))  // negative clamps to 0
        let changes = ChangedLines(files: ["a": Set([5])])
        #expect(changes.contains(line: 1, in: "a", tolerance: Int.max))
    }

    @Test("hunk starts near Int.max are rejected instead of trapping downstream")
    func extremeHunkStart() {
        // Fits in Int, so the checked digit parser alone would accept it;
        // the line-number cap must reject it before newLine += 1 can trap.
        let diff = """
            diff --git a/x b/x
            --- a/x
            +++ b/x
            @@ -1 +9223372036854775807 @@
            +x

            """
        #expect(ChangedLines(diff: diff).isEmpty)
        #expect(DiffParser.parseHunkHeader(ArraySlice("@@ -1 +\(DiffParser.maxLineNumber + 1),1 @@".utf8)) == nil)
        // The largest accepted value must survive a full hunk without traps.
        let boundary = """
            diff --git a/x b/x
            --- a/x
            +++ b/x
            @@ -1 +\(DiffParser.maxLineNumber) @@
            +x

            """
        #expect(ChangedLines(diff: boundary).lineSets == ["x": [DiffParser.maxLineNumber]])
    }

    @Test("a deletion-only hunk cannot invent added lines")
    func deletionOnlyHunkStrayPlus() {
        // The "+y" is malformed: the hunk declared zero new-side lines.
        let diff = """
            diff --git a/A b/A
            --- a/A
            +++ b/A
            @@ -1,2 +0,0 @@
            -x
            +y
            -z

            """
        #expect(ChangedLines(diff: diff).isEmpty)
    }

    @Test("a '+' beyond the declared new-side count re-parses as a header")
    func malformedCountRecoversNextFile() {
        // The new side is exhausted after "+y"; the following "+++ b/B.swift"
        // must be recognized as a header, not miscounted as content.
        let diff = """
            diff --git a/A b/A
            --- a/A
            +++ b/A
            @@ -3,3 +1,1 @@
            -x
            +y
            +++ b/B.swift
            @@ -1 +1,2 @@
             x
            +z

            """
        #expect(ChangedLines(diff: diff).lineSets == [
            "A": [1],
            "B.swift": [2],
        ])
    }

    @Test("clang 'fatal error:' diagnostics are recognized as errors")
    func fatalErrorSeverity() {
        let log = "/repo/t.c:1:10: fatal error: 'nope.h' file not found"
        #expect(ClangStyleLogParser.diagnostics(in: log) == [
            Diagnostic(
                path: "/repo/t.c", line: 1, column: 10,
                severity: .error, message: "'nope.h' file not found"
            )
        ])
    }
}
