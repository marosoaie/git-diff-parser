import GitDiffKit
import Testing

/// The samples of Handling Damaged Input.
extension DocumentationSampleTests {
    @Test("Damaged Input: reading damage reports")
    func damageReports() {
        var printedLines: [String] = []
        func print(_ items: Any...) { printedLines.append(Self.printed(items)) }

        let truncated = """
            diff --git a/notes.txt b/notes.txt
            --- a/notes.txt
            +++ b/notes.txt
            @@ -1,3 +1,4 @@
             first
            +second
            """
        let summary = DiffSummary(diff: truncated)
        summary.damage.forEach { report in
            print(report.severity, report.reason, "at line", report.lineNumber)
        }
        // info hunkCutShort at line 7
        print(summary.files.map(\.addedLineCount))   // [1]

        #expect(printedLines == ["info hunkCutShort at line 7", "[1]"])
    }
}
