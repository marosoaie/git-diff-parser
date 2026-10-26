import Testing
@testable import GitDiffKit

@Suite("Diff summary")
struct DiffSummaryTests {
    private static func path(_ string: String) -> DiffPath { DiffPath(Array(string.utf8)) }

    /// One file of each status git writes, with edits where git allows them.
    static let statuses = """
        commit 0123456789abcdef0123456789abcdef01234567
        Author: A U Thor <author@example.com>

            Touch one file of each kind

        diff --git a/keep.txt b/keep.txt
        index 1111111..2222222 100644
        --- a/keep.txt
        +++ b/keep.txt
        @@ -1,3 +1,4 @@ heading
         one
        -two
        +2
        +two and a half
         three
        @@ -10 +11 @@
        -ten
        +10
        diff --git a/added.txt b/added.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/added.txt
        @@ -0,0 +1,2 @@
        +new
        +file
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100755
        index 4444444..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old name.txt b/new name.txt
        similarity index 90%
        rename from old name.txt
        rename to new name.txt
        index 5555555..6666666 100644
        --- a/old name.txt
        +++ b/new name.txt
        @@ -2 +2 @@
        -line
        +LINE
        diff --git a/source.txt b/copy.txt
        similarity index 100%
        copy from source.txt
        copy to copy.txt
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git a/image.png b/image.png
        index 7777777..8888888 100644
        Binary files a/image.png and b/image.png differ

        """

    @Test("each file gets its header and both line counts, in input order")
    func statusesAndCounts() {
        let summary = DiffSummary(diff: Self.statuses)
        #expect(summary.damage.isEmpty)
        #expect(summary.files.map(\.header.change) == [
            .modified, .added, .deleted, .renamed(similarity: 90), .copied(similarity: 100), .modified, .modified,
        ])
        #expect(summary.files.map { ($0.header.newPath ?? $0.header.oldPath)?.string } == [
            "keep.txt", "added.txt", "gone.txt", "new name.txt", "copy.txt", "run.sh", "image.png",
        ])
        #expect(summary.files.map { [$0.addedLineCount, $0.deletedLineCount] } == [
            [3, 2], [2, 0], [0, 1], [1, 1], [0, 0], [0, 0], [0, 0],
        ])
        #expect(summary.files.map(\.header.modeChanged) == [false, false, false, false, false, true, false])
        #expect(summary.files.map(\.header.isBinary) == [false, false, false, false, false, false, true])
        #expect(summary.files[3].header.oldPath == Self.path("old name.txt"))
        #expect(summary.files[2].header.oldMode == .executable)
    }

    @Test("the summary is the same for any chunking", arguments: [1, 2, 3, 7, 64])
    func chunkInvariance(chunkSize: Int) {
        let bytes = Array((Self.statuses + StreamingTests.fixture).utf8)
        #expect(DiffSummary.of(bytes, chunkSize: chunkSize) == DiffSummary.of(bytes))
    }

    @Test("the String and byte entry points agree, and bytes needn't be UTF-8")
    func entryPoints() {
        #expect(DiffSummary(diff: Array(Self.statuses.utf8)) == DiffSummary(diff: Self.statuses))

        let latin1 = Array("""
            diff --git a/caf\u{E9}.txt b/caf\u{E9}.txt
            --- a/caf\u{E9}.txt
            +++ b/caf\u{E9}.txt
            @@ -1 +1 @@
            -x
            +y

            """.unicodeScalars.map { UInt8($0.value) })
        let files = DiffSummary(diff: latin1).files
        #expect(files.map(\.header.newPath) == [DiffPath(Array("caf".utf8) + [0xE9] + Array(".txt".utf8))])
        #expect(files.map { [$0.addedLineCount, $0.deletedLineCount] } == [[1, 1]])
    }

    @Test("a combined diff is listed with no line counts, and the file after it is counted")
    func combinedDiff() {
        let diff = """
            diff --cc merged.txt
            index 1111111,2222222..3333333
            --- a/merged.txt
            +++ b/merged.txt
            @@@ -1,2 -1,2 +1,2 @@@
              same
            - ours
             -theirs
            ++both
            diff --git a/next.txt b/next.txt
            --- a/next.txt
            +++ b/next.txt
            @@ -1 +1,2 @@
             same
            +added

            """
        let summary = DiffSummary(diff: diff)
        #expect(summary.damage.isEmpty)
        #expect(summary.files.map(\.header.format) == [.combined(parents: 2), .git])
        #expect(summary.files.map { [$0.addedLineCount, $0.deletedLineCount] } == [[0, 0], [1, 0]])
    }

    @Test("damage is kept in input order, and an abandoned file is left out")
    func damage() {
        let diff = """
            @@ -1 +1 @@
            -before any file
            +before any file
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
        let summary = DiffSummary(diff: diff)
        #expect(summary.damage.map(\.reason) == [.hunkWithoutFile, .hunkCutShort, .headerTooLarge])
        #expect(summary.damage.map(\.lineNumber) == [1, 10, 74])
        #expect(summary.damage.map { $0.file?.newPath?.string } == [nil, "cut.txt", "big.txt"])
        #expect(summary.files.map(\.header.newPath?.string) == ["cut.txt", "next.txt"])
        #expect(summary.files.map { [$0.addedLineCount, $0.deletedLineCount] } == [[1, 1], [1, 1]])
    }

    @Test("events out of the parser's order neither trap nor invent files")
    func outOfOrderEvents() {
        let header = FileHeader(format: .git, change: .modified, newPath: Self.path("f.txt"))
        let empty: [UInt8] = []
        var collector = DiffSummary.Collector()
        collector.line(LineInfo(kind: .addition, oldNumber: nil, newNumber: 1), content: empty.span)
        collector.endFile()
        collector.beginFile(header, rawHeader: empty.span)
        collector.line(LineInfo(kind: .addition, oldNumber: nil, newNumber: 1), content: empty.span)
        // A second file starting without endFile closes the first.
        collector.beginFile(header, rawHeader: empty.span)
        collector.line(LineInfo(kind: .deletion, oldNumber: 1, newNumber: nil), content: empty.span)
        collector.endFile()
        collector.endFile()
        #expect(collector.summary.files == [
            DiffSummary.File(header: header, addedLineCount: 1),
            DiffSummary.File(header: header, deletedLineCount: 1),
        ])
    }
}
