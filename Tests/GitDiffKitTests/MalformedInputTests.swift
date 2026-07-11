import Testing
@testable import GitDiffKit

/// Regression tests for hostile or malformed input: none of these may crash,
/// and recoverable damage must stay contained to the malformed file.
@Suite("Malformed input")
struct MalformedInputTests {
    @Test("a bare '+++ ' header with an empty payload does not crash")
    func emptyFileHeaderPayload() {
        let diff = "diff --git a/x b/x\n"
            + "--- a/x\n"
            + "+++ \n"
            + "@@ -0,0 +1 @@\n"
            + "+z\n"
        // No usable path, so the added line has nowhere to be recorded.
        #expect(ChangedLines(diff: diff).isEmpty)
        #expect(DiffParser.parseFileHeaderPath("") == nil)
        #expect(DiffParser.parseFileHeaderPath("\t2024-01-01") == nil)
    }

    @Test("a diff truncated mid-hunk neither invents lines nor loses the next file")
    func truncatedHunk() {
        let diff = "diff --git a/A.swift b/A.swift\n"
            + "--- a/A.swift\n"
            + "+++ b/A.swift\n"
            + "@@ -1,5 +1,5 @@\n"    // declares 5 lines per side...
            + " ctx\n"
            + "+added\n"             // ...but is cut off after two
            + "diff --git a/B.swift b/B.swift\n"
            + "--- a/B.swift\n"
            + "+++ b/B.swift\n"
            + "@@ -1 +1,2 @@\n"
            + " x\n"
            + "+y\n"
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
        let diff = "diff --git a/x b/x\n"
            + "--- a/x\n"
            + "+++ b/x\n"
            + "\(header)\n"
            + "+z\n"
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

    @Test("clang 'fatal error:' diagnostics are recognized as errors")
    func fatalErrorSeverity() {
        let log = "/repo/t.c:1:10: fatal error: 'nope.h' file not found"
        #expect(LogParser.diagnostics(in: log) == [
            Diagnostic(
                path: "/repo/t.c", line: 1, column: 10,
                severity: .error, message: "'nope.h' file not found"
            )
        ])
    }
}
