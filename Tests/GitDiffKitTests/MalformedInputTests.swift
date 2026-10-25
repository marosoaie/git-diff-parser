import Testing
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
        // The +++ path is unusable, so the diff --git line's name stands in.
        #expect(ChangedLines(diff: diff).lineSets == ["x": [1]])
        // Without one, the added line has nowhere to be recorded: the +++
        // line is empty, or all trailer.
        ["", "\t2024-01-01"].forEach { payload in
            #expect(ChangedLines(diff: "--- /dev/null\n+++ \(payload)\n@@ -0,0 +1 @@\n+z\n").isEmpty)
        }
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
        #expect(HunkHeader.parse(ArraySlice(header.utf8)) == nil)
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
        #expect(HunkHeader.parse(ArraySlice("@@ -1 +\(HunkHeader.maxLineNumber + 1),1 @@".utf8)) == nil)
        // The largest accepted value must survive a full hunk without traps.
        let boundary = """
            diff --git a/x b/x
            --- a/x
            +++ b/x
            @@ -1 +\(HunkHeader.maxLineNumber) @@
            +x

            """
        #expect(ChangedLines(diff: boundary).lineSets == ["x": [HunkHeader.maxLineNumber]])
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

    @Test("a line beyond the declared counts re-parses as a header")
    func malformedCountRecoversNextFile() {
        // The old side is exhausted after "-x"; the following "--- a/B.swift"
        // must be recognized as a header, not miscounted as content.
        let diff = """
            diff --git a/A b/A
            --- a/A
            +++ b/A
            @@ -1,1 +1,2 @@
            -x
            +y
            --- a/B.swift
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

    @Test("a lone '+++' after an exhausted hunk is neither content nor a header")
    func loneNewSideAfterHunk() {
        // The new side is exhausted after "+y", so "+++ b/B.swift" isn't
        // counted as content; without a "---" it starts no file, as in
        // `git apply`, and the next hunk stays in A.
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
        #expect(ChangedLines(diff: diff).lineSets == ["A": [1, 2]])
    }
}
