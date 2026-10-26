import Testing
@testable import GitDiffKit

/// The full model's file type on its own: built from parts, read back
/// through its collections, compared by content.
@Suite("Diff file")
struct DiffFileTests {
    private static func bytes(_ string: String) -> ArraySlice<UInt8> { Array(string.utf8)[...] }

    private static let header = FileHeader(
        format: .git, change: .modified, oldPath: DiffPath(Array("f.txt".utf8)), newPath: DiffPath(Array("f.txt".utf8))
    )

    private static func line(
        _ kind: LineInfo.Kind, _ old: Int?, _ new: Int?, _ content: String, noNewline: Bool = false
    ) -> DiffLine {
        DiffLine(
            info: LineInfo(kind: kind, oldNumber: old, newNumber: new),
            content: bytes(content),
            hasNoNewlineAtEnd: noNewline
        )
    }

    private static let file = DiffFile(
        header: header,
        rawHeader: bytes("diff --git a/f.txt b/f.txt\r\n--- a/f.txt\n+++ b/f.txt\n"),
        leadingLines: [DiffTextLine(content: bytes("junk before the first hunk"))],
        hunks: [
            DiffHunk(
                header: HunkHeader(oldStart: 1, oldCount: 2, newStart: 1, newCount: 2),
                heading: bytes(" func one()"),
                lines: [line(.context, 1, 1, "same"), line(.deletion, 2, nil, "old")],
                trailingLines: [
                    DiffTextLine(content: bytes("-- "), endsWithCarriageReturn: true),
                    DiffTextLine(content: bytes("2.50.0")),
                ]
            ),
            DiffHunk(
                header: HunkHeader(oldStart: 9, oldCount: 1, newStart: 9, newCount: 1),
                lines: [line(.deletion, 9, nil, "nine"), line(.addition, nil, 9, "NINE", noNewline: true)]
            ),
        ]
    )

    @Test("a file built from parts reads them back through its collections")
    func readsBackParts() {
        let file = Self.file
        #expect(file.rawHeader == Self.bytes("diff --git a/f.txt b/f.txt\r\n--- a/f.txt\n+++ b/f.txt\n"))
        #expect(file.binaryPatchLines.isEmpty)
        #expect(file.leadingLines.map(\.content) == [Self.bytes("junk before the first hunk")])
        #expect(file.hunks.count == 2)
        #expect(file.hunks.map(\.heading) == [Self.bytes(" func one()"), []])
        #expect(file.hunks.map(\.header.oldStart) == [1, 9])
        #expect(file.hunks[0].trailingLines.map(\.content) == [Self.bytes("-- "), Self.bytes("2.50.0")])
        #expect(file.hunks[0].trailingLines.map(\.endsWithCarriageReturn) == [true, false])
        #expect(file.hunks[1].trailingLines.isEmpty)
        #expect(file.lines.map(\.content) == ["same", "old", "nine", "NINE"].map(Self.bytes))
        #expect(file.lines.map(\.hasNoNewlineAtEnd) == [false, false, false, true])
    }

    @Test("a hunk's lines are indexed from 0, whichever hunk it is")
    func zeroBasedIndices() {
        let second = Self.file.hunks[1]
        #expect(second.lines.indices == 0..<2)
        #expect(second.lines[0] == Self.line(.deletion, 9, nil, "nine"))
        #expect(second.lines.last == Self.line(.addition, nil, 9, "NINE", noNewline: true))
        #expect(Array(second.lines.reversed()).map(\.info.kind) == [.addition, .deletion])
        #expect(Self.file.hunks[0].trailingLines.indices == 0..<2)
    }

    @Test("files compare by content, not by how their storage is laid out")
    func equality() {
        // The same content, with the hunk collection built on its own first.
        let hunks = DiffFile.Hunks(Array(Self.file.hunks))
        let rebuilt = DiffFile(
            header: Self.header,
            rawHeader: Array(Self.file.rawHeader)[...],
            leadingLines: DiffFile.TextLines(Array(Self.file.leadingLines)),
            hunks: hunks
        )
        #expect(rebuilt == Self.file)

        var otherHeader = Self.header
        otherHeader.change = .renamed(similarity: 90)
        #expect(DiffFile(header: otherHeader, hunks: hunks) != DiffFile(header: Self.header, hunks: hunks))
        let hunkAt = { (start: Int) in
            DiffHunk(header: HunkHeader(oldStart: start, oldCount: 1, newStart: start, newCount: 1))
        }
        #expect(DiffFile(header: Self.header, hunks: [hunkAt(1)]) != DiffFile(header: Self.header, hunks: [hunkAt(2)]))
        let flagged: DiffFile.Lines = [Self.line(.addition, nil, 1, "x", noNewline: true)]
        let plain: DiffFile.Lines = [Self.line(.addition, nil, 1, "x")]
        #expect(flagged != plain)
        #expect(DiffFile.Lines([Self.line(.addition, nil, 1, "x")]) == plain)
        #expect(DiffFile.TextLines([DiffTextLine(content: Self.bytes("a"), endsWithCarriageReturn: true)])
            != [DiffTextLine(content: Self.bytes("a"))])
    }

    @Test("line records keep every number exactly, nil apart from 0, and every flag")
    func lineRecords() {
        let infos = [
            LineInfo(kind: .context, oldNumber: 0, newNumber: 0),
            LineInfo(kind: .addition, oldNumber: nil, newNumber: Int.max, endsWithCarriageReturn: true),
            LineInfo(kind: .deletion, oldNumber: Int.min, newNumber: nil, isTruncated: true),
            LineInfo(
                kind: .context, oldNumber: -1, newNumber: 1 << 48, endsWithCarriageReturn: true, isTruncated: true
            ),
            LineInfo(kind: .addition, oldNumber: nil, newNumber: nil),
        ]
        let lines = DiffFile.Lines(infos.map { DiffLine(info: $0, content: Self.bytes("c")) })
        #expect(lines.map(\.info) == infos)
        // The record's size is what the model's memory figure rests on.
        #expect(MemoryLayout<DiffFile.LineRecord>.stride == 32)
    }

    @Test("empty collections and an empty file hold nothing")
    func empty() {
        let file = DiffFile(header: Self.header)
        #expect(file.rawHeader.isEmpty)
        #expect(file.hunks.isEmpty && file.lines.isEmpty)
        #expect(file.leadingLines.isEmpty && file.binaryPatchLines.isEmpty)
        let lines: DiffFile.Lines = [DiffLine(info: LineInfo(kind: .context, oldNumber: 1, newNumber: 1), content: [])]
        #expect(lines.map(\.content) == [[]])
    }
}
