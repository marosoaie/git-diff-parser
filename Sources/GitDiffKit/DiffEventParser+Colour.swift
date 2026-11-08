extension DiffEventParser {
    /// `line` without git's colour codes, so a coloured diff parses as a
    /// plain one. For a line that starts with an escape, any line of a
    /// coloured file, since git ends even context lines with a reset, and
    /// a `diff ` line, whose only code may be that reset.
    mutating func removingColour(from line: RawLine) -> RawLine {
        var plain = line
        plain.bytes = Self.removingColourCodes(from: line.bytes)
        guard plain.bytes.count != line.bytes.count else { return plain }
        lastLineWithColourCodes = lineNumber
        // Git writes a CRLF line's `\r` before its closing reset.
        if !line.endsWithCarriageReturn, !line.isTruncated, plain.bytes.last == UInt8(ascii: "\r") {
            plain.bytes.removeLast()
            plain.endsWithCarriageReturn = true
        }
        return plain
    }

    /// `bytes` without their SGR sequences (`ESC [`, digits, `;` or `:`,
    /// then `m`); any other escape stays. Each code goes as its `m` closes
    /// it, so one that removing another closes goes too (`ESC ESC[m [m`),
    /// and the result holds none: a model renders back to itself. Linear in
    /// the bytes.
    static func removingColourCodes(from bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard let firstEscape = bytes.firstIndex(of: DiffSyntax.escape) else { return bytes }
        var plain = Array(bytes[..<firstEscape])
        plain.reserveCapacity(bytes.count)
        bytes[firstEscape...].forEach { byte in
            plain.append(byte)
            if byte == UInt8(ascii: "m"), let start = colourCodeStart(endingAt: plain) {
                plain.removeSubrange(start...)
            }
        }
        return plain[...]
    }

    /// Where the SGR sequence that `bytes` ends with starts, if it ends
    /// with one. The scan back stops at the first byte that isn't a
    /// parameter, and an `m` that stays is one, so no byte is scanned twice.
    private static func colourCodeStart(endingAt bytes: [UInt8]) -> Int? {
        let parameters = UInt8(ascii: "0")...UInt8(ascii: ";")
        guard let bracket = bytes.dropLast().lastIndex(where: { !parameters.contains($0) }),
              bracket > 0,
              bytes[bracket] == UInt8(ascii: "["),
              bytes[bracket - 1] == DiffSyntax.escape
        else { return nil }
        return bracket - 1
    }
}
