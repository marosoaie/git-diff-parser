import Foundation
import Testing
@testable import BuildLogKit
@testable import GitDiffKit

@Suite("LineRangeSet")
struct LineRangeSetTests {
    @Test("in-order inserts merge into runs")
    func inOrderMerging() {
        var ranges = LineRangeSet()
        for line in [1, 2, 3, 7, 8, 20] {
            ranges.insert(line)
        }
        #expect(ranges.ranges == [1...3, 7...8, 20...20])
        #expect(ranges.lineCount == 6)
        #expect(ranges.allLines == [1, 2, 3, 7, 8, 20])
    }

    @Test("duplicate and out-of-order inserts normalize")
    func outOfOrderInserts() {
        var ranges = LineRangeSet()
        for line in [10, 11, 3, 10, 5, 4, 30, 12] {
            ranges.insert(line)
        }
        #expect(ranges.ranges == [3...5, 10...12, 30...30])
    }

    @Test("range insert swallows everything it overlaps or touches")
    func rangeInsertMerging() {
        var ranges = LineRangeSet([1...2, 5...6, 9...10, 20...20])
        ranges.insert(3...9)
        #expect(ranges.ranges == [1...10, 20...20])
    }

    @Test("ranges touching Int extremes never trap")
    func intExtremes() {
        var ranges = LineRangeSet()
        ranges.insert(Int.max...Int.max)
        ranges.insert(5...6)                       // out-of-order below a maxed tail
        ranges.insert((Int.max - 1)...Int.max)     // merges into the tail
        ranges.insert(8...9)
        #expect(ranges.ranges == [5...6, 8...9, (Int.max - 1)...Int.max])
        #expect(ranges.contains(Int.max))
        #expect(!ranges.contains(7))
        #expect(ranges.contains(7, tolerance: 1))

        var negatives = LineRangeSet()
        negatives.insert(Int.min...Int.min)
        // Distance from -1 is exactly Int.max; from 0 it is Int.max + 1.
        #expect(negatives.contains(-1, tolerance: Int.max))
        #expect(!negatives.contains(0, tolerance: Int.max))
    }

    @Test("lineCount saturates instead of trapping on uncountable ranges")
    func lineCountSaturation() {
        #expect(LineRangeSet([Int.min...Int.max]).lineCount == Int.max)
        #expect(LineRangeSet([0...(Int.max - 1)]).lineCount == Int.max)
        #expect(LineRangeSet([1...3, (Int.max - 2)...Int.max]).lineCount == 6)
    }

    @Test("contains uses binary search with optional tolerance")
    func contains() {
        let ranges = LineRangeSet([5...7, 100...200, 500...500])
        #expect(ranges.contains(5))
        #expect(ranges.contains(7))
        #expect(ranges.contains(150))
        #expect(!ranges.contains(4))
        #expect(!ranges.contains(8))
        #expect(!ranges.contains(499))
        #expect(ranges.contains(4, tolerance: 1))
        #expect(ranges.contains(8, tolerance: 1))
        #expect(ranges.contains(503, tolerance: 3))
        #expect(!ranges.contains(504, tolerance: 3))
    }
}

@Suite("Streaming")
struct StreamingTests {
    /// A diff exercising several files, hunks, a new file, a deletion,
    /// a quoted path, and tricky content lines.
    static let fixture: String = {
        var diff = #"""
        diff --git a/Sources/App/Foo.swift b/Sources/App/Foo.swift
        --- a/Sources/App/Foo.swift
        +++ b/Sources/App/Foo.swift
        @@ -10,6 +10,7 @@ struct Foo {
             let a = 1
        -    let b = 2
        +    let b = 22
        +    let c = 3
             let d = 4
             tail
             tail
             tail
        diff --git a/Gone.swift b/Gone.swift
        --- a/Gone.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -bye
        -bye
        diff --git "a/sp\303\266cial.swift" "b/sp\303\266cial.swift"
        --- "a/sp\303\266cial.swift"
        +++ "b/sp\303\266cial.swift"
        @@ -1,2 +1,4 @@
         first
        +++ plus-prefixed content
        +@@ not a hunk
         last

        """#
        // A big generated new file so runs collapse into a single range.
        diff += """
            diff --git a/Big.swift b/Big.swift
            --- /dev/null
            +++ b/Big.swift
            @@ -0,0 +1,5000 @@

            """
        diff += (1...5000).map { "+line \($0) with some ünïcode ✅ padding\n" }.joined()
        return diff
    }()

    static let expected: [String: Set<Int>] = [
        "Sources/App/Foo.swift": [11, 12],
        "spöcial.swift": [2, 3],
        "Big.swift": Set(1...5000),
    ]

    @Test("whole-string parse matches expectations")
    func wholeString() {
        let changes = ChangedLines(diff: Self.fixture)
        #expect(changes.lineSets == Self.expected)
        // The generated file must collapse to a single range.
        #expect(changes.ranges(in: "Big.swift") == [1...5000])
    }

    @Test(
        "chunked parsing is byte-for-byte equivalent to whole-string parsing",
        arguments: [1, 2, 3, 7, 64, 1000, 1 << 20]
    )
    func chunkedEquivalence(chunkSize: Int) {
        let bytes = Array(Self.fixture.utf8)
        var parser = DiffParser()
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            parser.consume(bytes[index..<end])
            index = end
        }
        let changes = parser.finalize()
        #expect(changes == ChangedLines(diff: Self.fixture))
        #expect(changes.lineSets == Self.expected)
    }

    @Test("input without a trailing newline still counts the last line")
    func unterminatedLastLine() {
        // No newline after the final line.
        let diff = """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -0,0 +1,2 @@
            +one
            +two
            """
        #expect(ChangedLines(diff: diff).lineSets == ["f.txt": [1, 2]])
    }

    @Test("CRLF line endings parse identically to LF")
    func crlf() {
        let lf = """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -1,2 +1,3 @@
             ctx
            +added
             ctx

            """
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(ChangedLines(diff: crlf) == ChangedLines(diff: lf))
        #expect(ChangedLines(diff: crlf).lineSets == ["f.txt": [2]])
    }

    @Test("over-long lines truncate uniformly, independent of chunking")
    func giantLineCap() {
        // A 1.5 MiB context line exceeds the 1 MiB cap; hunk accounting and
        // the following added line must be unaffected, whatever the chunking.
        let giant = String(repeating: "g", count: (1 << 20) + (1 << 19))
        let diff = """
            diff --git a/f b/f
            --- a/f
            +++ b/f
            @@ -1,2 +1,2 @@
             \(giant)
            +z

            """
        let whole = ChangedLines(diff: diff)
        #expect(whole.lineSets == ["f": [2]])

        let bytes = Array(diff.utf8)
        for chunkSize in [1 << 14, (1 << 20) + 37] {
            var parser = DiffParser()
            var index = 0
            while index < bytes.count {
                let end = min(index + chunkSize, bytes.count)
                parser.consume(bytes[index..<end])
                index = end
            }
            #expect(parser.finalize() == whole, "chunk size \(chunkSize)")
        }

        // Same for logs: a diagnostic starting beyond the cap is dropped,
        // and identically so for any chunking.
        let junk = String(repeating: "j", count: (1 << 20) + 100)
        let log = """
            \(junk) /repo/A.swift:1:1: warning: beyond the cap
            /repo/B.swift:2:2: warning: kept

            """
        let wholeLog = ClangStyleLogParser.diagnostics(in: log)
        #expect(wholeLog.map(\.path) == ["/repo/B.swift"])
        var logParser = ClangStyleLogParser()
        let logBytes = Array(log.utf8)
        var index = 0
        while index < logBytes.count {
            let end = min(index + (1 << 14), logBytes.count)
            logParser.consume(logBytes[index..<end])
            index = end
        }
        #expect(logParser.finalize() == wholeLog)
    }

    @Test("log parsing is chunk-size independent", arguments: [1, 3, 17, 4096])
    func logChunkedEquivalence(chunkSize: Int) {
        let log = """
        Compiling Swift Module 'App' (3 sources)
        /repo/Sources/App/Foo.swift:42:13: warning: unused ünïcode variable
        random noise without any marker
        /repo/Sources/App/Foo.swift:42:13: warning: unused ünïcode variable
        /repo/B.swift:1: error: boom
        """
        let bytes = Array(log.utf8)
        var parser = ClangStyleLogParser()
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            parser.consume(bytes[index..<end])
            index = end
        }
        let streamed = parser.finalize()
        #expect(streamed == ClangStyleLogParser.diagnostics(in: log))
        #expect(streamed.count == 2)
    }
}
