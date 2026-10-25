import Testing
@testable import GitDiffKit

/// One test per `DamageReport.Reason`: where it is reported, how severe it
/// is, which file it names, and that parsing goes on with the next file.
@Suite("Damage reports")
struct DamageReportTests {
    private typealias Event = EventRecorder.Event

    /// A well-formed file that follows the damage, to show recovery.
    private static let nextFile = """
        diff --git a/next.txt b/next.txt
        --- a/next.txt
        +++ b/next.txt
        @@ -1 +1 @@
        -old
        +new

        """

    /// The single report in `events`, recorded as an issue when there are
    /// more or fewer.
    private static func onlyReport(
        in events: [Event], sourceLocation: SourceLocation = #_sourceLocation
    ) -> DamageReport? {
        let reports = EventRecorder.damage(in: events)
        #expect(reports.count == 1, "\(reports)", sourceLocation: sourceLocation)
        return reports.first
    }

    /// The paths of the files that began, in order.
    private static func files(in events: [Event]) -> [String] {
        events.compactMap { event in
            guard case let .beginFile(header, _) = event else { return nil }
            return header.newPath?.string ?? header.oldPath?.string ?? "nil"
        }
    }

    /// Whether `events` end with `nextFile`'s two lines, parsed in full.
    private static func endsWithNextFile(_ events: [Event]) -> Bool {
        Array(events.suffix(3)) == [
            .line(LineInfo(kind: .deletion, oldNumber: 1, newNumber: nil), content: Array("old".utf8)),
            .line(LineInfo(kind: .addition, oldNumber: nil, newNumber: 1), content: Array("new".utf8)),
            .endFile,
        ]
    }

    @Test("a hunk cut short by the next file is reported at that file's diff line")
    func hunkCutShortByNextFile() {
        let diff = """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -1,3 +1,3 @@
             one
            -two

            """ + Self.nextFile
        let events = EventRecorder.events(in: diff)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .hunkCutShort)
        #expect(report?.severity == .info)
        #expect(report?.lineNumber == 7)
        #expect(report?.file?.newPath?.string == "f.txt")
        #expect(Self.files(in: events) == ["f.txt", "next.txt"])
        #expect(Self.endsWithNextFile(events))
    }

    @Test("a hunk cut short by the end of input is reported one past the last line")
    func hunkCutShortAtEnd() {
        let diff = """
            --- a/f.txt
            +++ b/f.txt
            @@ -1,3 +1,3 @@
             one

            """
        let report = Self.onlyReport(in: EventRecorder.events(in: diff))
        #expect(report?.reason == .hunkCutShort)
        #expect(report?.lineNumber == 5)
        #expect(report?.file?.newPath?.string == "f.txt")
    }

    @Test("a line that doesn't fit the hunk's remaining counts ends it and is read again outside")
    func hunkCutShortByMisfit() {
        let diff = """
            --- a/f.txt
            +++ b/f.txt
            @@ -1,2 +1,1 @@
             one
            +doesn't fit

            """
        let events = EventRecorder.events(in: diff)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .hunkCutShort)
        #expect(report?.lineNumber == 5)
        #expect(events.contains(.unrecognizedLine(Array("+doesn't fit".utf8), endsWithCarriageReturn: false)))
    }

    @Test("a hunk line without a marker is context and reported; an empty line is context and not")
    func missingLineMarker() {
        let diff = """
            --- a/f.txt
            +++ b/f.txt
            @@ -1,3 +1,3 @@
            unmarked

             three

            """
        let events = EventRecorder.events(in: diff)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .missingLineMarker)
        #expect(report?.severity == .info)
        #expect(report?.lineNumber == 4)
        let unmarked = LineInfo(kind: .context, oldNumber: 1, newNumber: 1)
        #expect(events.contains(.line(unmarked, content: Array("unmarked".utf8))))
        #expect(events.contains(.line(LineInfo(kind: .context, oldNumber: 2, newNumber: 2), content: [])))
    }

    @Test("a no-newline marker that follows no hunk line is reported and dropped")
    func misplacedNoNewlineMarker() {
        let diff = """
            --- a/f.txt
            +++ b/f.txt
            @@ -1 +1 @@
            \\ No newline at end of file
            -a
            +b

            """
        let events = EventRecorder.events(in: diff)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .misplacedNoNewlineMarker)
        #expect(report?.lineNumber == 4)
        #expect(!events.contains(.noNewlineAtEndOfFile))
        #expect(events.filter { if case .line = $0 { true } else { false } }.count == 2)
    }

    @Test(
        "a header value that doesn't parse is reported and ignored, and the file kept",
        arguments: ["old mode 10o644", "similarity index 101%", "index xyz..abc 100644"]
    )
    func ignoredHeaderValue(line: String) {
        let diff = """
            diff --git a/f.txt b/f.txt
            \(line)
            --- a/f.txt
            +++ b/f.txt
            @@ -1 +1 @@
            -a
            +b

            """
        let events = EventRecorder.events(in: diff)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .ignoredHeaderValue)
        #expect(report?.severity == .info)
        #expect(report?.lineNumber == 2)
        #expect(report?.file?.newPath?.string == "f.txt")
        #expect(Self.files(in: events) == ["f.txt"])
        #expect(events.filter { if case .line = $0 { true } else { false } }.count == 2)
    }

    @Test("a malformed hunk header is reported and passed on as an unrecognized line")
    func malformedHunkHeader() {
        let diff = """
            --- a/f.txt
            +++ b/f.txt
            @@ -x +y @@

            """ + Self.nextFile
        let events = EventRecorder.events(in: diff)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .malformedHunkHeader)
        #expect(report?.lineNumber == 3)
        #expect(report?.file?.newPath?.string == "f.txt")
        #expect(events.contains(.unrecognizedLine(Array("@@ -x +y @@".utf8), endsWithCarriageReturn: false)))
        #expect(Self.endsWithNextFile(events))
    }

    @Test("a hunk before any file is reported, and its lines dropped even when they look like headers")
    func hunkWithoutFile() {
        let diff = """
            @@ -1,2 +1,2 @@
            --- a/looks-like-a-header
            +++ b/looks-like-a-header

            """ + Self.nextFile
        let events = EventRecorder.events(in: diff)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .hunkWithoutFile)
        #expect(report?.severity == .info)
        #expect(report?.lineNumber == 1)
        #expect(report?.file == nil)
        #expect(Self.files(in: events) == ["next.txt"])
        #expect(!events.contains { if case .unrecognizedLine = $0 { true } else { false } })
        #expect(Self.endsWithNextFile(events))
    }

    @Test(
        "a binary patch that ends inside a part, or starts with neither literal nor delta, is reported",
        arguments: [
            (body: "literal 5\nzzzzz\n", line: 6),
            (body: "nonsense 5\n", line: 4),
        ]
    )
    func malformedBinaryPatch(body: String, line: Int) {
        let diff = """
            diff --git a/b.bin b/b.bin
            index 1111111..2222222 100644
            GIT binary patch

            """ + body + Self.nextFile
        let events = EventRecorder.events(in: diff)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .malformedBinaryPatch)
        #expect(report?.severity == .info)
        #expect(report?.lineNumber == line)
        #expect(report?.file?.newPath?.string == "b.bin")
        #expect(Self.files(in: events) == ["b.bin", "next.txt"])
        #expect(Self.endsWithNextFile(events))
    }

}

// MARK: Damage that abandons a file

extension DamageReportTests {
    @Test(
        "an oversized header abandons its file: no beginFile, its lines dropped, the next file parsed",
        arguments: [
            // 65 lines: the `diff` line and 64 `index` lines; the 65th is
            // one too many.
            (String(repeating: "index 1111111..2222222\n", count: 64), 65),
            // Two lines under the line cap that together pass 1 MiB.
            (String(repeating: "rename from \(String(repeating: "x", count: 600_000))\n", count: 2), 3),
            // One line over the line cap.
            ("rename from \(String(repeating: "x", count: 1 << 20))\n", 2),
        ]
    )
    func headerTooLarge(extraHeaderLines: String, reportedAt lineNumber: Int) {
        let diff = """
            diff --git a/big.txt b/big.txt
            \(extraHeaderLines)--- a/big.txt
            +++ b/big.txt
            @@ -1 +1 @@
            -dropped
            +dropped

            """ + Self.nextFile
        let events = EventRecorder.events(in: diff)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .headerTooLarge)
        #expect(report?.severity == .error)
        #expect(report?.lineNumber == lineNumber)
        #expect(report?.file?.newPath?.string == "big.txt")
        #expect(Self.files(in: events) == ["next.txt"])
        #expect(!events.contains { if case .line(_, Array("dropped".utf8)) = $0 { true } else { false } })
        #expect(Self.endsWithNextFile(events))
    }

    @Test("a combined diff against 65 parents abandons its file up to the next diff line; 64 are fine")
    func tooManyParents() {
        let combined = { (parents: Int) in
            // N + 1 markers around a range per parent and one for the result.
            let markers = String(repeating: "@", count: parents + 1)
            let ranges = String(repeating: "-1 ", count: parents) + "+1"
            return """
                diff --cc merged.txt
                index \(Array(repeating: "1111111", count: parents).joined(separator: ","))..2222222
                --- a/merged.txt
                +++ b/merged.txt
                \(markers) \(ranges) \(markers)
                \(String(repeating: " ", count: parents))unchanged

                """
        }
        let accepted = EventRecorder.events(in: combined(64))
        #expect(EventRecorder.damage(in: accepted).isEmpty)
        guard case let .beginFile(header, _) = accepted.first else {
            Issue.record("expected beginFile, got \(accepted)")
            return
        }
        #expect(header.format == .combined(parents: 64))

        let events = EventRecorder.events(in: combined(65) + Self.nextFile)
        let report = Self.onlyReport(in: events)
        #expect(report?.reason == .tooManyParents)
        #expect(report?.severity == .error)
        #expect(report?.lineNumber == 5)
        #expect(Self.files(in: events) == ["next.txt"])
        #expect(Self.endsWithNextFile(events))
    }

    @Test("severity is error exactly for the reasons that abandon a file")
    func severities() {
        let reasons: [DamageReport.Reason] = [
            .hunkCutShort, .missingLineMarker, .misplacedNoNewlineMarker, .ignoredHeaderValue,
            .malformedHunkHeader, .hunkWithoutFile, .malformedBinaryPatch, .headerTooLarge, .tooManyParents,
        ]
        let errors = reasons.filter { DamageReport(reason: $0, lineNumber: 1, file: nil).severity == .error }
        #expect(errors == [.headerTooLarge, .tooManyParents])
        #expect(DamageReport.Severity.info < .error)
    }
}
