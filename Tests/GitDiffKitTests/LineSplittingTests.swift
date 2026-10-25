import Testing
@testable import GitDiffKit

@Suite("Line splitting")
struct LineSplittingTests {
    /// What the splitter hands on for one line, copied out.
    struct Line: Equatable, CustomStringConvertible {
        var bytes: [UInt8]
        var endsWithCarriageReturn: Bool
        var isTruncated: Bool
        var isTerminated: Bool

        var description: String {
            """
            \(String(decoding: bytes, as: UTF8.self)) cr=\(endsWithCarriageReturn) \
            truncated=\(isTruncated) terminated=\(isTerminated)
            """
        }
    }

    struct Recorder: ByteLineConsumer {
        var carry: LineCarry
        var lines: [Line] = []

        mutating func processLine(_ line: RawLine) {
            lines.append(Line(
                bytes: Array(line.bytes),
                endsWithCarriageReturn: line.endsWithCarriageReturn,
                isTruncated: line.isTruncated,
                isTerminated: line.isTerminated
            ))
        }
    }

    static func lines(of text: String, cap: Int, chunkSize: Int) -> [Line] {
        let bytes = Array(text.utf8)
        var recorder = Recorder(carry: LineCarry(maximumLength: cap))
        stride(from: 0, to: bytes.count, by: chunkSize).forEach { start in
            recorder.consumeChunk(bytes[start..<min(start + chunkSize, bytes.count)])
        }
        recorder.flushPartialLine()
        return recorder.lines
    }

    /// Lines of exactly the cap, one byte over it, a `\r` sitting exactly at
    /// the cap, and an unterminated last line.
    static let input = "abcd\nabcd\r\nabcde\nabc\r\r\nabcde\r\n\r\nab\r"

    @Test("carriage returns and truncation are flagged from the real line, not the capped one")
    func flagsAtTheCap() {
        let expected = [
            Line(bytes: Array("abcd".utf8), endsWithCarriageReturn: false, isTruncated: false, isTerminated: true),
            Line(bytes: Array("abcd".utf8), endsWithCarriageReturn: true, isTruncated: false, isTerminated: true),
            Line(bytes: Array("abcd".utf8), endsWithCarriageReturn: false, isTruncated: true, isTerminated: true),
            // "abc\r" is the content: the first `\r` sits at the cap.
            Line(bytes: Array("abc\r".utf8), endsWithCarriageReturn: true, isTruncated: false, isTerminated: true),
            Line(bytes: Array("abcd".utf8), endsWithCarriageReturn: true, isTruncated: true, isTerminated: true),
            Line(bytes: [], endsWithCarriageReturn: true, isTruncated: false, isTerminated: true),
            Line(bytes: Array("ab".utf8), endsWithCarriageReturn: true, isTruncated: false, isTerminated: false),
        ]
        #expect(Self.lines(of: Self.input, cap: 4, chunkSize: .max) == expected)
    }

    @Test("every chunking yields the same lines and flags", arguments: 1...12)
    func chunkInvariance(chunkSize: Int) {
        let whole = Self.lines(of: Self.input, cap: 4, chunkSize: .max)
        #expect(Self.lines(of: Self.input, cap: 4, chunkSize: chunkSize) == whole)
    }

    @Test("a zero cap keeps every line empty but still splits and flags them", arguments: [1, 3, Int.max])
    func zeroCap(chunkSize: Int) {
        let lines = Self.lines(of: "ab\n\r\nc", cap: 0, chunkSize: chunkSize)
        #expect(lines.map(\.bytes) == [[], [], []])
        #expect(lines.map(\.isTruncated) == [true, false, true])
        #expect(lines.map(\.endsWithCarriageReturn) == [false, true, false])
        #expect(lines.map(\.isTerminated) == [true, true, false])
    }
}
