import Testing
@testable import GitDiffKit

@Suite("Full diff model")
struct DiffTests {
    private static func bytes(_ string: String) -> ArraySlice<UInt8> { Array(string.utf8)[...] }

    static let logWithCommits = """
        commit aaaaaaa
        Author: A <a@example.com>

            First

        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -a
        +A

        commit bbbbbbb
        Author: B <b@example.com>

            Second

        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -1,2 +1,2 @@ heading
         keep
        -b
        +B
        \\ No newline at end of file
        --\u{20}
        2.50.0

        """

    static let crlf = [
        "diff --git a/w.txt b/w.txt", "--- a/w.txt", "+++ b/w.txt",
        "@@ -1,2 +1,2 @@ section", " one", "-two", "+TWO", "",
    ].joined(separator: "\r\n")

    static let binaryPatch = """
        diff --git a/img.bin b/img.bin
        index 1111111..2222222 100644
        GIT binary patch
        literal 8
        PcmeAS@N;M2<X{H?3F!fc

        literal 7
        OcmeAS@N;KiWC8#POaXEL

        diff --git a/next.txt b/next.txt
        --- a/next.txt
        +++ b/next.txt
        @@ -1 +1 @@
        -old
        +new

        """

    static let plain = """
        --- old/f.txt\t2026-10-26 01:00:00.000000000 +0100
        +++ new/f.txt\t2026-10-26 01:00:01.000000000 +0100
        @@ -1 +1 @@
        -x
        +y
        Only in new: extra.txt

        """

    static let combinedAndDamaged = """
        diff --cc merged.txt
        index 1111111,2222222..3333333
        --- a/merged.txt
        +++ b/merged.txt
        @@@ -1,2 -1,2 +1,2 @@@
          same
        - ours
         -theirs
        ++both
        diff --git a/cut.txt b/cut.txt
        --- a/cut.txt
        +++ b/cut.txt
        @@ -1,3 +1,3 @@
        -one
        +ONE
        diff --git a/big.txt b/big.txt
        \(String(repeating: "index 1111111..2222222\n", count: 64))--- a/big.txt
        +++ b/big.txt
        @@ -1 +1 @@
        -dropped
        +dropped
        diff --git a/next.txt b/next.txt
        --- a/next.txt
        +++ b/next.txt
        @@ -1 +1 @@
        -old
        +new

        """

    @Test("the model holds every event the parser sends, in order", arguments: Sample.allCases)
    func holdsEveryEvent(sample: Sample) {
        let diff = Diff.of(sample.bytes)
        let expected = EventRecorder.eventsWithoutDamage(in: sample.bytes)
        Oracle.expectEqualEntries(diff.replayedEvents, expected)
        #expect(diff.damage == EventRecorder.damage(in: EventRecorder.events(in: sample.bytes)))
    }

    @Test("the model is the same for any chunking", arguments: Sample.allCases)
    func chunkInvariance(sample: Sample) {
        let whole = Diff.of(sample.bytes)
        [1, 2, 5, 13].forEach { chunkSize in
            #expect(Diff.of(sample.bytes, chunkSize: chunkSize) == whole, "chunk size \(chunkSize)")
        }
    }

    @Test("the model agrees with the summary on every file's header, counts, and damage", arguments: Sample.allCases)
    func agreesWithSummary(sample: Sample) {
        let diff = Diff.of(sample.bytes)
        let summary = DiffSummary.of(sample.bytes)
        #expect(diff.files.map(\.header) == summary.files.map(\.header))
        #expect(diff.lineCounts == summary.files.map { [$0.addedLineCount, $0.deletedLineCount] })
        #expect(diff.damage == summary.damage)
    }

    @Test("lines keep their numbers, content, headings, and no-newline flag")
    func linesAndHunks() {
        let diff = Diff(diff: Self.logWithCommits)
        #expect(diff.files.map(\.header.newPath?.string) == ["a.txt", "b.txt"])
        let file = diff.files[1]
        #expect(file.hunks.map(\.heading) == [Self.bytes(" heading")])
        #expect(file.lines.map(\.info) == [
            LineInfo(kind: .context, oldNumber: 1, newNumber: 1),
            LineInfo(kind: .deletion, oldNumber: 2, newNumber: nil),
            LineInfo(kind: .addition, oldNumber: nil, newNumber: 2),
        ])
        #expect(file.lines.map(\.content) == ["keep", "b", "B"].map(Self.bytes))
        #expect(file.lines.map(\.hasNoNewlineAtEnd) == [false, false, true])
        #expect(file.rawHeader == Self.bytes("diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n"))
    }

    @Test("unrecognized lines land in the preamble, or after the hunk they follow")
    func unrecognizedLines() {
        let diff = Diff(diff: Self.logWithCommits)
        let text = { (lines: DiffFile.TextLines) in lines.map { String(decoding: $0.content, as: UTF8.self) } }
        #expect(text(diff.preamble) == ["commit aaaaaaa", "Author: A <a@example.com>", "", "    First", ""])
        #expect(text(diff.files[0].hunks[0].trailingLines) == [
            "", "commit bbbbbbb", "Author: B <b@example.com>", "", "    Second", "",
        ])
        #expect(text(diff.files[1].hunks[0].trailingLines) == ["-- ", "2.50.0"])
        #expect(diff.files.allSatisfy { $0.leadingLines.isEmpty })

        let plain = Diff(diff: Self.plain)
        #expect(plain.files.map(\.header.format) == [.unified])
        #expect(text(plain.files[0].hunks[0].trailingLines) == ["Only in new: extra.txt"])
    }

    @Test("carriage returns stay out of the content and are flagged, and the raw header keeps them")
    func carriageReturns() {
        let file = Diff(diff: Self.crlf).files[0]
        #expect(file.rawHeader == Self.bytes("diff --git a/w.txt b/w.txt\r\n--- a/w.txt\r\n+++ b/w.txt\r\n"))
        #expect(file.hunks.map(\.heading) == [Self.bytes(" section")])
        #expect(file.lines.map(\.content) == ["one", "two", "TWO"].map(Self.bytes))
        #expect(file.lines.allSatisfy { $0.info.endsWithCarriageReturn })
    }

    @Test("a binary patch is kept verbatim, without hunks, and the next file parses")
    func binaryPatchLines() {
        let diff = Diff(diff: Self.binaryPatch)
        let file = diff.files[0]
        #expect(file.header.isBinary)
        #expect(file.rawHeader.suffix(17) == Self.bytes("GIT binary patch\n"))
        #expect(file.binaryPatchLines.map(\.content) == [
            "literal 8", "PcmeAS@N;M2<X{H?3F!fc", "", "literal 7", "OcmeAS@N;KiWC8#POaXEL", "",
        ].map(Self.bytes))
        #expect(file.hunks.isEmpty && file.leadingLines.isEmpty)
        #expect(diff.files.map(\.header.newPath?.string) == ["img.bin", "next.txt"])
        #expect(diff.damage.isEmpty)
    }

    @Test("a combined diff keeps its raw header and no hunks; an abandoned file is left out, its damage kept")
    func combinedAndDamage() {
        let diff = Diff(diff: Self.combinedAndDamaged)
        #expect(diff.files.map(\.header.newPath?.string) == ["merged.txt", "cut.txt", "next.txt"])
        #expect(diff.files[0].header.format == .combined(parents: 2))
        #expect(diff.files[0].hunks.isEmpty && diff.files[0].leadingLines.isEmpty)
        #expect(String(decoding: diff.files[0].rawHeader, as: UTF8.self).hasPrefix("diff --cc merged.txt\nindex "))
        #expect(diff.damage.map(\.reason) == [.hunkCutShort, .headerTooLarge])
        #expect(diff.lineCounts == [[0, 0], [1, 1], [1, 1]])
    }

    @Test("the full model's entry points keep a 2 MiB line whole; the parser's default cap cuts it")
    func lineCap() {
        let long = String(repeating: "x", count: 2 << 20)
        let text = "--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+\(long)\n"
        let whole = Diff(diff: text).files[0].lines[0]
        #expect(whole.content.count == 2 << 20 && !whole.info.isTruncated)
        #expect(Diff(diff: Array(text.utf8)).files[0].lines[0] == whole)

        let cut = DiffEventParser.collect(Diff.Collector(), from: Array(text.utf8)).diff.files[0].lines[0]
        #expect(cut.info.isTruncated)
        // The cap counts the marker column.
        #expect(cut.content.count == (1 << 20) - 1)

        #expect(ParsingOptions.fullModel.maximumLineLength == 64 << 20)
        #expect(DiffEventParser<Diff.Collector>().carry.maximumLength == 64 << 20)
        let small = DiffEventParser<Diff.Collector>(options: ParsingOptions(maximumLineLength: 4))
        #expect(small.carry.maximumLength == 4)
    }

    @Test("the String and byte entry points agree, and content needn't be UTF-8")
    func entryPoints() {
        #expect(Diff(diff: Array(Self.logWithCommits.utf8)) == Diff(diff: Self.logWithCommits))
        let latin1: [UInt8] = Array("--- a/f\n+++ b/f\n@@ -1 +1 @@\n-caf".utf8) + [0xE9]
            + Array("\n+caf".utf8) + [0xE9, 0x21, 0x0A]
        #expect(Diff(diff: latin1).files[0].lines.map(\.content) == [
            Array("caf".utf8)[...] + [0xE9], Array("caf".utf8)[...] + [0xE9, 0x21],
        ])
    }

    @Test("events out of the parser's order neither trap nor lose the order of what is kept")
    func outOfOrderEvents() {
        let header = FileHeader(format: .git, change: .modified, newPath: DiffPath(Array("f.txt".utf8)))
        let text = { (string: String) in Array(string.utf8) }
        let info = LineInfo(kind: .addition, oldNumber: nil, newNumber: 1)
        var collector = Diff.Collector()
        collector.line(info, content: text("no file").span)
        collector.beginHunk(HunkHeader(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1), heading: text("").span)
        collector.noNewlineAtEndOfFile(endsWithCarriageReturn: false)
        collector.endFile()
        collector.beginFile(header, rawHeader: text("raw\n").span)
        collector.line(info, content: text("before any hunk").span)
        collector.noNewlineAtEndOfFile(endsWithCarriageReturn: false)
        collector.beginHunk(HunkHeader(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1), heading: text("").span)
        collector.line(info, content: text("kept").span)
        // A second file starting without endFile closes the first.
        collector.beginFile(header, rawHeader: text("raw\n").span)
        collector.endFile()
        collector.unrecognizedLine(text("after the last file").span, endsWithCarriageReturn: false)
        let diff = collector.diff
        #expect(diff.preamble.isEmpty)
        #expect(diff.files.count == 2)
        #expect(diff.files[0].lines.map(\.content) == [Self.bytes("kept")])
        #expect(!diff.files[0].lines[0].hasNoNewlineAtEnd)
        #expect(diff.files[1].leadingLines.map(\.content) == [Self.bytes("after the last file")])
    }
}

extension DiffTests {
    /// Inputs covering every kind of event. The tests take the case, not
    /// the text, to keep swift-testing's printed arguments short.
    enum Sample: CaseIterable {
        case statuses
        case streaming
        case logWithCommits
        case crlf
        case binaryPatch
        case plain
        case combinedAndDamaged
        case crlfWithMarkers
        case unterminated
        case bareContextLine

        var text: String {
            switch self {
            case .statuses: DiffSummaryTests.statuses
            case .streaming: StreamingTests.fixture
            case .logWithCommits: DiffTests.logWithCommits
            case .crlf: DiffTests.crlf
            case .binaryPatch: DiffTests.binaryPatch
            case .plain: DiffTests.plain
            case .combinedAndDamaged: DiffTests.combinedAndDamaged
            case .crlfWithMarkers: LineEndingTests.crlfWithMarkers
            case .unterminated: "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b"
            case .bareContextLine: "--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n one\n\n-two\n+TWO\n"
            }
        }

        var bytes: [UInt8] { Array(text.utf8) }
    }
}
