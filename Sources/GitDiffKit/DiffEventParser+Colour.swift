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
    /// then `m`); any other escape stays. Linear in the bytes.
    static func removingColourCodes(from bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard let firstEscape = bytes.firstIndex(of: DiffSyntax.escape) else { return bytes }
        var plain = Array(bytes[..<firstEscape])
        plain.reserveCapacity(bytes.count)
        var index = firstEscape
        // A cursor that jumps over whole sequences: a byte scan that
        // combinators would obscure.
        while index < bytes.endIndex {
            if bytes[index] == DiffSyntax.escape, let end = colourCodeEnd(in: bytes, at: index) {
                index = end
            } else {
                plain.append(bytes[index])
                index += 1
            }
        }
        return plain[...]
    }

    /// The index past the SGR sequence that starts at `start`, if one does.
    /// Its scan stops at the next escape, so no byte is scanned twice.
    private static func colourCodeEnd(in bytes: ArraySlice<UInt8>, at start: Int) -> Int? {
        let rest = bytes[(start + 1)...]
        guard rest.first == UInt8(ascii: "[") else { return nil }
        let parameters = rest.dropFirst().prefix { (UInt8(ascii: "0")...UInt8(ascii: ";")).contains($0) }
        guard parameters.endIndex < bytes.endIndex, bytes[parameters.endIndex] == UInt8(ascii: "m") else {
            return nil
        }
        return parameters.endIndex + 1
    }
}
