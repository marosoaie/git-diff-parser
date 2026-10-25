import Foundation
import Testing
@testable import GitDiffKit

@Suite("Diff events")
struct DiffEventParserTests {
    private typealias Event = EventRecorder.Event

    private static func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    private static func path(_ string: String) -> DiffPath { DiffPath(bytes(string)) }

    @Test("a typical git diff streams header, hunk, and lines in order")
    func typicalOrdering() {
        let rawHeader = """
            diff --git a/f.txt b/f.txt
            index 1234567..89abcde 100644
            --- a/f.txt
            +++ b/f.txt

            """
        let diff = rawHeader + """
            @@ -1,3 +1,3 @@ func main()
             one
            -two
            +TWO
             three

            """
        let header = FileHeader(
            format: .git,
            change: .modified,
            oldPath: Self.path("f.txt"),
            newPath: Self.path("f.txt"),
            oldMode: FileMode(rawValue: 0o100644),
            newMode: FileMode(rawValue: 0o100644),
            oldObjectID: ObjectID(hex: Self.bytes("1234567")[...]),
            newObjectID: ObjectID(hex: Self.bytes("89abcde")[...])
        )
        let expected: [Event] = [
            .beginFile(header, rawHeader: Self.bytes(rawHeader)),
            .beginHunk(
                HunkHeader(oldStart: 1, oldCount: 3, newStart: 1, newCount: 3),
                heading: Self.bytes(" func main()")
            ),
            .line(LineInfo(kind: .context, oldNumber: 1, newNumber: 1), content: Self.bytes("one")),
            .line(LineInfo(kind: .deletion, oldNumber: 2, newNumber: nil), content: Self.bytes("two")),
            .line(LineInfo(kind: .addition, oldNumber: nil, newNumber: 2), content: Self.bytes("TWO")),
            .line(LineInfo(kind: .context, oldNumber: 3, newNumber: 3), content: Self.bytes("three")),
            .endFile,
        ]
        #expect(EventRecorder.events(in: diff) == expected)
    }

    @Test("line numbers follow each hunk's starts across several hunks and files")
    func lineNumbers() {
        let diff = """
            --- a/one.txt
            +++ b/one.txt
            @@ -10,2 +10,3 @@
             ten
            +new eleven
             eleven
            @@ -40 +41,0 @@
            -forty
            --- a/two.txt
            +++ b/two.txt
            @@ -0,0 +1 @@
            +first

            """
        let lines = EventRecorder.events(in: diff).compactMap { event -> LineInfo? in
            guard case let .line(info, _) = event else { return nil }
            return info
        }
        #expect(lines == [
            LineInfo(kind: .context, oldNumber: 10, newNumber: 10),
            LineInfo(kind: .addition, oldNumber: nil, newNumber: 11),
            LineInfo(kind: .context, oldNumber: 11, newNumber: 12),
            LineInfo(kind: .deletion, oldNumber: 40, newNumber: nil),
            LineInfo(kind: .addition, oldNumber: nil, newNumber: 1),
        ])
    }

    @Test("a pure rename gets beginFile and endFile and nothing else")
    func pureRename() {
        let diff = """
            diff --git a/old name.txt b/new name.txt
            similarity index 100%
            rename from old name.txt
            rename to new name.txt
            diff --git a/next.txt b/next.txt
            --- a/next.txt
            +++ b/next.txt
            @@ -1 +1 @@
            -a
            +b

            """
        let events = EventRecorder.events(in: diff)
        guard case let .beginFile(header, rawHeader) = events.first else {
            Issue.record("expected beginFile, got \(events)")
            return
        }
        #expect(header.change == .renamed(similarity: 100))
        #expect(header.oldPath == Self.path("old name.txt"))
        #expect(header.newPath == Self.path("new name.txt"))
        #expect(rawHeader == Self.bytes(diff.components(separatedBy: "diff --git a/next")[0]))
        #expect(events.count == 7)
        #expect(events[1] == .endFile)
        guard case let .beginFile(next, _) = events[2] else {
            Issue.record("expected the second file to begin, got \(events[2])")
            return
        }
        #expect(next.newPath == Self.path("next.txt"))
        #expect(events.last == .endFile)
    }

    @Test("lines outside any file — before, between, and after — are unrecognized lines")
    func unrecognizedLines() {
        let diff = """
            From 1234 Mon Sep 17 00:00:00 2001
            Subject: [PATCH] change

            ---
             f.txt | 2 +-
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -1 +1 @@
            -a
            +b
            Only in dir: stray
            diff --git a/g.txt b/g.txt
            deleted file mode 100644
            --\u{20}
            2.45.0

            """
        let events = EventRecorder.events(in: diff)
        let unrecognized = events.compactMap { event -> String? in
            guard case let .unrecognizedLine(content, false) = event else { return nil }
            return String(decoding: content, as: UTF8.self)
        }
        #expect(unrecognized == [
            "From 1234 Mon Sep 17 00:00:00 2001", "Subject: [PATCH] change", "", "---", " f.txt | 2 +-",
            "Only in dir: stray", "-- ", "2.45.0",
        ])
        #expect(EventRecorder.damage(in: events).isEmpty)
        let shape = events.map { event -> String in
            switch event {
            case .beginFile: "begin"
            case .endFile: "end"
            case .unrecognizedLine: "?"
            case .line: "line"
            case .beginHunk: "hunk"
            default: "\(event)"
            }
        }
        // A file stays open until the next one starts or input ends, so
        // lines after its hunks arrive before its endFile.
        #expect(shape == [
            "?", "?", "?", "?", "?", "begin", "hunk", "line", "line", "?", "end", "begin", "?", "?", "end",
        ])
    }

    @Test("the raw header keeps carriage returns and the heading keeps its leading space")
    func verbatimSpans() {
        let rawHeader = "diff --git a/f.txt b/f.txt\r\n--- a/f.txt\r\n+++ b/f.txt\r\n"
        let diff = rawHeader + "@@ -1 +1 @@  two  spaces\t\r\n-a\r\n+b\r\n"
        let events = EventRecorder.events(in: diff)
        guard case let .beginFile(header, raw) = events.first, case let .beginHunk(_, heading) = events[1] else {
            Issue.record("expected beginFile and beginHunk, got \(events)")
            return
        }
        #expect(raw == Self.bytes(rawHeader))
        #expect(header.newPath == Self.path("f.txt"))
        #expect(heading == Self.bytes("  two  spaces\t"))
        #expect(events[2] == .line(
            LineInfo(kind: .deletion, oldNumber: 1, newNumber: nil, endsWithCarriageReturn: true),
            content: Self.bytes("a")
        ))
        #expect(events[3] == .line(
            LineInfo(kind: .addition, oldNumber: nil, newNumber: 1, endsWithCarriageReturn: true),
            content: Self.bytes("b")
        ))
    }

    @Test(
        "carriage-return and truncation flags at the line cap are the same for every chunk size",
        arguments: [1, 2, 3, 5, 7, 8, 9, 13]
    )
    func flagsAtTheCap(chunkSize: Int) {
        // Lines of 15, 16, and 17 bytes, marker included, around a cap of 16
        // (which the 15-byte hunk header fits), with and without a `\r`;
        // the `\r` never counts toward the cap.
        let contents = [14, 15, 16].map { String(repeating: "x", count: $0) }
        let lines = contents.flatMap { ["+\($0)\n", "+\($0)\r\n"] }
        let diff = Self.bytes("--- a/f\n+++ b/f\n@@ -0,0 +1,6 @@\n" + lines.joined())
        let options = ParsingOptions(maximumLineLength: 16)
        let events = EventRecorder.events(in: diff, chunkSize: chunkSize, options: options)
        let observed = events.compactMap { event -> LineInfo? in
            guard case let .line(info, content) = event else { return nil }
            #expect(content.count == min(15, 14 + (info.newNumber! - 1) / 2), "line \(info.newNumber!)")
            return info
        }
        let expected = (1...6).map { number in
            LineInfo(
                kind: .addition,
                oldNumber: nil,
                newNumber: number,
                endsWithCarriageReturn: number.isMultiple(of: 2),
                isTruncated: number > 4
            )
        }
        #expect(observed == expected)
        #expect(events == EventRecorder.events(in: diff, options: options))
    }

}

// MARK: Diffs from git and real-world fixtures

extension DiffEventParserTests {
    @Test("a real --binary diff streams its patch lines and keeps parsing the next file")
    func binaryPatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-binary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repository.git", isDirectory: true)
        let blob = (0..<300).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let commit = { (blob: [UInt8], text: String) -> [FastImport.Command] in
            [
                .file(path: Self.bytes("blob.bin"), content: blob),
                .file(path: Self.bytes("z.txt"), content: Self.bytes(text)),
            ]
        }
        try FastImport.makeRepository(at: repository, commits: [commit(blob, "a\n"), commit(blob.reversed(), "b\n")])
        let diff = Array(try FastImport.git(["diff", "--binary", "main~1", "main"], in: repository))
        let events = EventRecorder.events(in: diff)
        let patchLines = events.compactMap { event -> [UInt8]? in
            guard case let .binaryPatchLine(content, false) = event else { return nil }
            return content
        }
        // Two parts (forward and reverse), each a literal/delta line, data,
        // and a blank line.
        let partHeaders = patchLines.filter { line in
            ["literal ", "delta "].contains { line.starts(with: Self.bytes($0)) }
        }
        #expect(partHeaders.count == 2)
        #expect(patchLines.filter(\.isEmpty).count == 2)
        let diffText = String(decoding: diff, as: UTF8.self)
        let block = diffText.components(separatedBy: "GIT binary patch\n")[1]
            .components(separatedBy: "diff --git")[0]
        let blockLines = block.components(separatedBy: "\n").dropLast()
        #expect(patchLines.map { String(decoding: $0, as: UTF8.self) } == Array(blockLines))
        #expect(EventRecorder.damage(in: events).isEmpty)
        let files = events.compactMap { event -> FileHeader? in
            guard case let .beginFile(header, _) = event else { return nil }
            return header
        }
        #expect(files.map(\.isBinary) == [true, false])
        #expect(files.map(\.newPath) == [Self.path("blob.bin"), Self.path("z.txt")])
        let addition = LineInfo(kind: .addition, oldNumber: nil, newNumber: 1)
        #expect(events.contains(.line(addition, content: Self.bytes("b"))))
    }

    @Test("a no-newline marker follows the line it belongs to, also the hunk's last line")
    func noNewlinePlacement() {
        let diff = """
            --- a/f
            +++ b/f
            @@ -1,2 +1,2 @@
             same
            -old
            \\ No newline at end of file
            +new
            \\ No newline at end of file
            --- a/g
            +++ b/g
            @@ -1 +1 @@
            -x
            +y

            """
        let events = EventRecorder.events(in: diff)
        let shape = events.map { event -> String in
            switch event {
            case let .line(info, _): "\(info.kind)"
            case .noNewlineAtEndOfFile: "\\"
            case .beginFile: "begin"
            case .endFile: "end"
            case .beginHunk: "hunk"
            default: "\(event)"
            }
        }
        #expect(shape == [
            "begin", "hunk", "context", "deletion", "\\", "addition", "\\", "end",
            "begin", "hunk", "deletion", "addition", "end",
        ])
    }

    @Test(
        "the whole event stream is the same for any chunking",
        .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil),
        arguments: [RealWorldFixture.redis, .swiftArgumentParser]
    )
    func chunkInvariance(fixture: RealWorldFixture) async throws {
        let diffURL = try await RealWorldFixtureStore.localDiffURL(for: fixture)
        let bytes = try Array(Data(contentsOf: diffURL))
        let whole = EventRecorder.events(in: bytes)
        #expect(whole.count > 10_000)
        // One-byte chunks take seconds per megabyte in debug builds.
        let chunkSizes = [4093, (1 << 20) + 7] + (bytes.count < 1 << 20 ? [1] : [])
        chunkSizes.forEach { chunkSize in
            #expect(EventRecorder.events(in: bytes, chunkSize: chunkSize) == whole, "chunk size \(chunkSize)")
        }
    }
}
