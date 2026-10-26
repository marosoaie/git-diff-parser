import Foundation
import Testing
@testable import GitDiffKit

/// Rendering the full model back to text: the parsed input byte for byte,
/// for any chunking of the input and of the output.
@Suite("Rendering")
struct RenderingTests {
    static func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    @Test("a diff renders back to its input, byte for byte, with no damage", arguments: Shape.allCases)
    func roundTrip(shape: Shape) {
        let input = shape.bytes
        let diff = Diff(diff: input)
        #expect(diff.damage.isEmpty)
        Oracle.expectEqualLines([UInt8](rendering: diff), input)
        // With its final newline gone, the input still renders back.
        let unterminated = Array(input.dropLast())
        Oracle.expectEqualLines([UInt8](rendering: Diff(diff: unterminated)), unterminated)
    }

    @Test(
        "every sample renders back, the same for any chunking of the input",
        arguments: DiffTests.Sample.allCases.filter { $0 != .combinedAndDamaged }
    )
    func samplesRoundTrip(sample: DiffTests.Sample) {
        let input = sample.bytes
        [.max, 1, 2, 5, 13].forEach { chunkSize in
            let rendered = [UInt8](rendering: Diff.of(input, chunkSize: chunkSize))
            #expect(rendered == input, "chunk size \(chunkSize)")
        }
    }

    @Test(
        "a last line without a newline renders back without one, wherever it lands",
        arguments: LineEndingTests.LastLine.allCases
    )
    func unterminatedLastLine(lastLine: LineEndingTests.LastLine) {
        let input = Self.bytes(lastLine.text)
        #expect([UInt8](rendering: Diff(diff: input)) == input)
        #expect([UInt8](rendering: Diff.of(input, chunkSize: 1)) == input)
    }

    @Test(
        "rendering in chunks of any size gives the same text, in chunks of at least the size",
        arguments: [1, 2, 7, 64]
    )
    func outputChunks(chunkSize: Int) {
        // Each shape as is and without its final newline; and a last file
        // with no bytes at all, so the final newline to drop is the one a
        // flush already reached.
        let header = FileHeader(format: .git, change: .modified)
        let diffs = Shape.allCases.flatMap { [Diff(diff: $0.bytes), Diff(diff: Array($0.bytes.dropLast()))] }
            + [Diff(files: Diff(diff: Shape.copy.bytes).files + [DiffFile(header: header)], hasNoNewlineAtEnd: true)]
        diffs.enumerated().forEach { index, diff in
            var chunks: [[UInt8]] = []
            diff.render(chunkSize: chunkSize) { chunks.append(Array($0)) }
            #expect(chunks.flatMap(\.self) == [UInt8](rendering: diff), "diff \(index)")
            #expect(chunks.allSatisfy { !$0.isEmpty }, "diff \(index)")
            #expect(chunks.dropLast().allSatisfy { $0.count >= chunkSize - 1 }, "diff \(index)")
        }
        #expect([UInt8](rendering: diffs.last ?? Diff()) == Array(Shape.copy.bytes.dropLast()))
        var whole: [UInt8] = []
        Diff(diff: Shape.modification.bytes).render { whole.append(contentsOf: $0) }
        #expect(whole == Shape.modification.bytes)
    }

    @Test("an empty diff renders as nothing, even flagged as unterminated")
    func empty() {
        #expect([UInt8](rendering: Diff()).isEmpty)
        #expect([UInt8](rendering: Diff(hasNoNewlineAtEnd: true)).isEmpty)
        var calls = 0
        Diff().render { _ in calls += 1 }
        #expect(calls == 0)
    }

    @Test("a combined diff renders as its header; a damaged file as what the model kept")
    func combinedAndDamaged() {
        let input = DiffTests.combinedAndDamaged
        let rendered = String(decoding: [UInt8](rendering: Diff(diff: input)), as: UTF8.self)
        let parts = input.components(separatedBy: "@@@ -1,2 -1,2 +1,2 @@@\n")
        let cutFile = "diff --git a/cut.txt b/cut.txt\n--- a/cut.txt\n+++ b/cut.txt\n@@ -1,3 +1,3 @@\n-one\n+ONE\n"
        let nextFile = "diff --git a/next.txt b/next.txt\n--- a/next.txt\n+++ b/next.txt\n@@ -1 +1 @@\n-old\n+new\n"
        // The abandoned big.txt is missing whole.
        #expect(rendered == parts[0] + cutFile + nextFile)
    }

    @Test("a model built by hand renders what it holds: the raw header, never the parsed header")
    func handBuilt() {
        var file = Diff(diff: Shape.renameWithEdits.bytes).files[0]
        file.header.newPath = DiffPath(Self.bytes("elsewhere.txt"))
        #expect([UInt8](rendering: Diff(files: [file])) == Shape.renameWithEdits.bytes)

        let hunk = DiffHunk(
            header: HunkHeader(oldStart: 1, oldCount: 2, newStart: 1, newCount: 1, oldCountIsImplicit: true,
                               newCountIsImplicit: true, endsWithCarriageReturn: true),
            heading: Self.bytes(" f()")[...],
            lines: [
                DiffLine(info: LineInfo(kind: .deletion, oldNumber: 1, newNumber: nil), content: Self.bytes("a")[...]),
                DiffLine(
                    info: LineInfo(kind: .context, oldNumber: 2, newNumber: 1, endsWithCarriageReturn: true),
                    content: Self.bytes("b")[...],
                    hasNoNewlineAtEnd: true,
                    noNewlineMarkerEndsWithCarriageReturn: true
                ),
            ]
        )
        let bare = DiffFile(header: file.header, hunks: [hunk])
        // An implicit count other than 1 is written, so the line says what
        // the header holds.
        let expected = "@@ -1,2 +1 @@ f()\r\n-a\n b\r\n\\ No newline at end of file\r\n"
        #expect([UInt8](rendering: Diff(files: [bare])) == Self.bytes(expected))
        #expect([UInt8](rendering: Diff(files: [bare], hasNoNewlineAtEnd: true)) == Self.bytes(expected).dropLast(1))

        // Only a context line goes without its marker.
        let unmarked = [LineInfo.Kind.addition, .deletion, .context].map { kind in
            let info = LineInfo(kind: kind, oldNumber: 1, newNumber: 1, hasNoMarker: true)
            let hunk = DiffHunk(
                header: HunkHeader(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1),
                lines: [DiffLine(info: info, content: Self.bytes("x")[...])]
            )
            let diff = Diff(files: [DiffFile(header: file.header, hunks: [hunk])])
            return String(decoding: [UInt8](rendering: diff), as: UTF8.self)
        }
        #expect(unmarked == ["@@ -1,1 +1,1 @@\n+x\n", "@@ -1,1 +1,1 @@\n-x\n", "@@ -1,1 +1,1 @@\nx\n"])
    }

    @Test("a diff of some of the files renders to a diff that parses to those files")
    func someFiles() {
        let diff = Diff(diff: Shape.gitShow.bytes)
        let some = Diff(files: diff.files.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element))
        let reparsed = Diff(diff: [UInt8](rendering: some))
        #expect(reparsed.files == some.files)
        #expect(reparsed.damage.isEmpty && reparsed.preamble.isEmpty)
    }

    @Test("an error thrown by write stops rendering and reaches the caller")
    func throwingWrite() {
        struct Stop: Error {}
        var calls = 0
        var caught: (any Error)?
        do {
            try Diff(diff: Shape.modification.bytes).render(chunkSize: 64) { _ in
                calls += 1
                if calls == 3 { throw Stop() }
            }
        } catch {
            caught = error
        }
        #expect(caught is Stop)
        #expect(calls == 3)
    }
}
