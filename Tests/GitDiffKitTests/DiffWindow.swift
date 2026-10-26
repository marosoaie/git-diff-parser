/// A clean stretch of diff to mutate: whole files, each starting at its
/// `diff ` line, optionally after a preamble.
///
/// Files are numbered from 1; file 0 is the preamble before the first
/// `diff ` line (empty for a window cut from a real diff).
struct DiffWindow {
    let bytes: [UInt8]
    /// Where each line starts, then `bytes.count`.
    let lineStarts: [Int]
    /// Each line's bytes, with its `\n`.
    let lines: [Range<Int>]
    /// Where each file's `diff ` line starts.
    let fileStarts: [Int]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        let starts = [0] + bytes.indices.filter { bytes[$0] == Self.newline }.map { $0 + 1 }
        lineStarts = starts.last == bytes.count ? starts : starts + [bytes.count]
        lines = zip(lineStarts, lineStarts.dropFirst()).map { $0..<$1 }
        fileStarts = lineStarts.dropLast().filter { bytes[$0...].starts(with: Self.diffPrefix) }
    }

    static let newline = UInt8(ascii: "\n")
    static let diffPrefix = Array("diff ".utf8)

    var fileCount: Int { fileStarts.count }

    /// The file holding the byte at `offset`; 0 for the preamble, and for
    /// an offset before the first byte.
    func file(containing offset: Int) -> Int {
        fileStarts.count { $0 <= offset }
    }

    /// The 0-based index of the line starting at `offset`.
    func lineIndex(startingAt offset: Int) -> Int {
        lineStarts.firstIndex(of: offset) ?? lineStarts.count - 1
    }

    func isLineStart(_ offset: Int) -> Bool {
        offset == 0 || bytes[offset - 1] == Self.newline
    }
}

extension DiffWindow {
    /// Where a mutation's effect on the lines lies.
    struct Footprint: Equatable {
        /// The original lines the edit changes, as a byte range from a line
        /// start; empty when it only inserts whole lines at `lines.lowerBound`.
        var lines: Range<Int>
        /// The files whose output the edit may change.
        var files: ClosedRange<Int>
    }

    /// The lines and files `mutation` touches: every file holding a line it
    /// changes, the file a whole-line insertion lands in (the one before the
    /// insertion point), and the file before one whose `diff ` line it
    /// breaks, since that file's other lines then join the previous one.
    func footprint(of mutation: Mutation) -> Footprint {
        let range = mutation.range
        let start = isLineStart(range.lowerBound)
            ? range.lowerBound
            : lineStarts.last { $0 < range.lowerBound } ?? 0
        // The line at `range.upperBound` is unchanged only if it still starts
        // a line: the edit ends at a line start and leaves a newline before it.
        let byteBeforeEnd = mutation.replacement.last ?? (range.lowerBound > 0 ? bytes[range.lowerBound - 1] : nil)
        let end = isLineStart(range.upperBound) && (byteBeforeEnd ?? Self.newline) == Self.newline
            ? range.upperBound
            : lineStarts.first { $0 > range.upperBound } ?? bytes.count
        guard start < end else {
            let file = file(containing: start - 1)
            return Footprint(lines: start..<start, files: file...file)
        }
        let first = file(containing: start)
        let mutated = mutation.applied(to: bytes)
        let breaksDiffLine = fileStarts.contains(start)
            && mutated.count > start
            && !mutated[start...].starts(with: Self.diffPrefix)
        return Footprint(lines: start..<end, files: (breaksDiffLine ? first - 1 : first)...file(containing: end - 1))
    }
}
