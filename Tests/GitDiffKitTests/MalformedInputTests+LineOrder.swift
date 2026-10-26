import Testing
@testable import GitDiffKit

/// Added lines in hostile orders — hunks that run backwards or overlap, a
/// path seen again below its earlier lines — come out as the plain union,
/// in O(n log n) time. Inserting each line in place once took 9 s on a
/// crafted 4 MB diff of backward hunks.
extension MalformedInputTests {
    /// A diff adding one line to `f` at each of `lines`, in that order, one
    /// hunk per line: in one file, or in a file per line.
    static func diff(adding lines: [Int], filePerLine: Bool) -> String {
        let header = "diff --git a/f b/f\n--- a/f\n+++ b/f\n"
        let hunks = lines.map { "@@ -\($0),0 +\($0) @@\n+x\n" }
        return filePerLine ? hunks.map { header + $0 }.joined() : header + hunks.joined()
    }

    @Test("hunks that run backwards or overlap add exactly their lines", arguments: [false, true])
    func backwardHunks(filePerLine: Bool) {
        let lines = [30, 10, 20, 10, 11, 9, 50, 1, 2, 3, 40, 39]
        let changes = ChangedLines(diff: Self.diff(adding: lines, filePerLine: filePerLine))
        #expect(changes.ranges(in: "f") == [1...3, 9...11, 20...20, 30...30, 39...40, 50...50])
    }

    @Test("a path repeated in any order gets the union of its lines, read midway or at the end")
    func repeatedPathUnion() {
        var generator = SplitMix64(seed: 7)
        let lines = (0..<600).map { _ in generator.next(in: 1...2000) }
        let bytes = Array(Self.diff(adding: lines, filePerLine: true).utf8)
        var parser = DiffEventParser(consumer: ChangedLines.Collector())
        parser.consume(bytes)
        // The last file is still open until the parser is finalized.
        #expect(parser.consumer.changedLines.lineSets == ["f": Set(lines.dropLast())])
        #expect(parser.finalize().changedLines.lineSets == ["f": Set(lines)])
    }

    @Test("lines in any order cost about what ascending lines cost, not quadratic time")
    func lineOrderComplexity() {
        // Events go straight to the collector, so parsing time doesn't
        // dilute the comparison. Quadratic insertion took over 10 s here.
        let ascending = (0..<200_000).map { $0 * 3 + 1 }
        [false, true].forEach { filePerLine in
            let inOrder = Self.collectionTime(of: ascending, filePerLine: filePerLine)
            let backwards = Self.collectionTime(of: Array(ascending.reversed()), filePerLine: filePerLine)
            #expect(backwards < inOrder * 5 + .milliseconds(500), "file per line: \(filePerLine)")
        }
    }

    private static func collectionTime(of lines: [Int], filePerLine: Bool) -> Duration {
        let path = DiffPath(Array("f".utf8))
        let header = FileHeader(format: .git, change: .modified, oldPath: path, newPath: path)
        let none: [UInt8] = []
        var collector = ChangedLines.Collector()
        let elapsed = ContinuousClock().measure {
            collector.beginFile(header, rawHeader: none.span)
            lines.forEach { number in
                if filePerLine {
                    collector.endFile()
                    collector.beginFile(header, rawHeader: none.span)
                }
                collector.line(LineInfo(kind: .addition, oldNumber: nil, newNumber: number), content: none.span)
            }
            collector.endFile()
            _ = collector.changedLines
        }
        #expect(collector.changedLines.files["f"]?.ranges.count == lines.count)
        return elapsed
    }
}
