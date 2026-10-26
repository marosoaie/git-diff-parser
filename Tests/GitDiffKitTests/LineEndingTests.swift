import Testing
@testable import GitDiffKit

/// How lines end, for rendering back: the `\r` of a diff stored with CRLF
/// line endings on every kind of line, a last line without `\n`, and a
/// context line without its marker column.
@Suite("Line endings")
struct LineEndingTests {
    private typealias Event = EventRecorder.Event

    private static func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    /// Every line ends in `\r\n`, as in a diff stored with CRLF line
    /// endings, the no-newline markers and hunk headers included.
    static let crlfWithMarkers = [
        "diff --git a/w.txt b/w.txt", "--- a/w.txt", "+++ b/w.txt", "@@ -1,2 +1,2 @@ section", " one", "-two",
        "\\ No newline at end of file", "+TWO", "\\ No newline at end of file", "",
    ].joined(separator: "\r\n")

    @Test("a diff stored with CRLF line endings flags the \\r of hunk headers and no-newline markers too")
    func carriageReturnsOnEveryLine() {
        let events = EventRecorder.events(in: Self.crlfWithMarkers)
        let header = HunkHeader(oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, endsWithCarriageReturn: true)
        #expect(events.contains(.beginHunk(header, heading: Self.bytes(" section"))))
        #expect(events.filter { $0 == .noNewlineAtEndOfFile(endsWithCarriageReturn: true) }.count == 2)
        #expect(!events.contains(.noNewlineAtEndOfFile(endsWithCarriageReturn: false)))
    }

    @Test("git's own CRLF output: content lines keep their \\r, and the hunk header and marker have none")
    func carriageReturnsInContentOnly() {
        // `git diff` of a CRLF file whose last line lost its newline: git
        // trims the heading, and writes the marker with `\n` alone.
        let diff = """
            --- a/f.txt
            +++ b/f.txt
            @@ -1,2 +1,2 @@ int main()
             a\r
            -b\r
            +c
            \\ No newline at end of file

            """
        let events = EventRecorder.events(in: diff)
        guard case let .beginHunk(header, heading) = events[1] else {
            Issue.record("expected beginHunk, got \(events[1])")
            return
        }
        #expect(!header.endsWithCarriageReturn)
        #expect(heading == Self.bytes(" int main()"))
        let carriageReturns = events.compactMap { event -> Bool? in
            guard case let .line(info, _) = event else { return nil }
            return info.endsWithCarriageReturn
        }
        #expect(carriageReturns == [true, true, false])
        #expect(events.contains(.noNewlineAtEndOfFile(endsWithCarriageReturn: false)))
    }

    /// Where an input's unterminated last line lands.
    enum LastLine: CaseIterable {
        case hunkLine
        case carriageReturn
        case noNewlineMarker
        case unrecognizedLine
        case oldSideLine
        case headerLine

        var text: String {
            let file = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b"
            return switch self {
            case .hunkLine: file
            case .carriageReturn: file + "\r"
            case .noNewlineMarker: file + "\n\\ No newline at end of file"
            case .unrecognizedLine: file + "\n-- \n2.50.0"
            case .oldSideLine: file + "\n--- a/g"
            case .headerLine: "diff --git a/f b/f\nold mode 100644\nnew mode 100755"
            }
        }
    }

    @Test(
        "an input whose last line has no newline ends with noNewlineAtEndOfInput, the same for any chunking",
        arguments: LastLine.allCases
    )
    func noNewlineAtEndOfInput(lastLine: LastLine) {
        let bytes = Self.bytes(lastLine.text)
        let events = EventRecorder.events(in: bytes)
        #expect(events.last == .noNewlineAtEndOfInput)
        #expect(events.filter { $0 == .noNewlineAtEndOfInput }.count == 1)
        #expect(EventRecorder.damage(in: events).isEmpty)
        [1, 2, 3].forEach { chunkSize in
            let chunked = EventRecorder.events(in: bytes, chunkSize: chunkSize)
            #expect(chunked == events, "chunk size \(chunkSize)")
        }
        let terminated = EventRecorder.events(in: bytes + Self.bytes("\n"))
        guard lastLine == .headerLine else {
            #expect(terminated == events.dropLast())
            return
        }
        // The raw header is verbatim, so it holds the newline or not.
        guard case let .beginFile(header, rawHeader) = events.first else {
            Issue.record("expected beginFile, got \(events)")
            return
        }
        #expect(rawHeader == bytes)
        #expect(terminated == [.beginFile(header, rawHeader: bytes + Self.bytes("\n"))] + events.dropFirst().dropLast())
    }

    @Test("a terminated input, an empty one, and one of only newlines send no noNewlineAtEndOfInput")
    func newlineAtEndOfInput() {
        ["", "\n", "\n\n", "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n"].forEach { text in
            #expect(!EventRecorder.events(in: text).contains(.noNewlineAtEndOfInput), "\(text.debugDescription)")
        }
    }

    @Test("an empty context line written without its space, as diff.suppressBlankEmpty writes it, is flagged")
    func contextLineWithoutMarker() {
        let events = EventRecorder.events(in: DiffTests.Sample.bareContextLine.text)
        let lines = events.compactMap { event -> LineInfo? in
            guard case let .line(info, _) = event else { return nil }
            return info
        }
        #expect(lines.map(\.hasNoMarker) == [false, true, false, false])
        #expect(lines[1] == LineInfo(kind: .context, oldNumber: 2, newNumber: 2, hasNoMarker: true))
        #expect(EventRecorder.damage(in: events).isEmpty)
    }

    @Test("the model keeps the \\r of hunk headers and markers, a bare context line, and a missing final newline")
    func model() {
        let crlf = Diff(diff: Self.crlfWithMarkers)
        #expect(crlf.files[0].hunks.map(\.header.endsWithCarriageReturn) == [true])
        #expect(crlf.files[0].lines.map(\.hasNoNewlineAtEnd) == [false, true, true])
        #expect(crlf.files[0].lines.map(\.noNewlineMarkerEndsWithCarriageReturn) == [false, true, true])
        #expect(!crlf.hasNoNewlineAtEnd)
        #expect(Diff(diff: DiffTests.crlf).files[0].hunks.map(\.header.endsWithCarriageReturn) == [true])

        let unterminated = Diff(diff: DiffTests.Sample.unterminated.text)
        #expect(unterminated.hasNoNewlineAtEnd)
        #expect(unterminated.files[0].lines.map(\.content) == [Self.bytes("a")[...], Self.bytes("b")[...]])
        #expect(Diff(diff: DiffTests.Sample.unterminated.text + "\n") == Diff(files: unterminated.files))

        let bare = Diff(diff: DiffTests.Sample.bareContextLine.text).files[0].lines
        #expect(bare.map(\.info.hasNoMarker) == [false, true, false, false])
        #expect(bare[1].content.isEmpty && bare[1].info.kind == .context)
    }
}
