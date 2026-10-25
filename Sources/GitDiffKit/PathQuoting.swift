/// Git's C-style path quoting, on bytes.
///
/// Git quotes a path that contains special bytes (control characters, `"`,
/// `\`, and with `core.quotePath` every non-ASCII byte): `"caf\303\251"`.
/// Unquoting yields the path's exact bytes, which need not be UTF-8.
enum PathQuoting {
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let octalDigits = UInt8(ascii: "0")...UInt8(ascii: "7")

    /// The bytes of a quoted path with its quoting undone, or the input
    /// unchanged when it isn't wrapped in quotes.
    static func unquoted(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        guard bytes.count >= 2, bytes.first == quote, bytes.last == quote else {
            return Array(bytes)
        }
        return unescaped(bytes.dropFirst().dropLast())
    }

    /// The index just past the closing quote of the quoted path `bytes`
    /// starts with, or nil if it doesn't start with one or never closes.
    static func endOfQuotedPrefix(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>.Index? {
        guard bytes.first == quote else { return nil }
        var index = bytes.index(after: bytes.startIndex)
        // A cursor rather than a search: a backslash hides the byte after it.
        while index < bytes.endIndex {
            switch bytes[index] {
            case quote: return bytes.index(after: index)
            case backslash: index = bytes.index(index, offsetBy: 2, limitedBy: bytes.endIndex) ?? bytes.endIndex
            default: index = bytes.index(after: index)
            }
        }
        return nil
    }

    /// Decodes the escapes inside a quoted path (without its quotes).
    ///
    /// A stateful cursor (complexity above the lint threshold): escapes
    /// consume a variable number of bytes, and splitting the escape table
    /// across helpers would obscure it. Unknown escapes keep the escaped
    /// byte, and an octal escape above 0o377 keeps its low byte, so no
    /// input is rejected.
    static func unescaped(_ body: ArraySlice<UInt8>) -> [UInt8] { // swiftlint:disable:this cyclomatic_complexity
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.count)
        var index = body.startIndex
        while index < body.endIndex {
            let byte = body[index]
            index += 1
            guard byte == backslash else {
                bytes.append(byte)
                continue
            }
            guard index < body.endIndex else { break }
            let escaped = body[index]
            index += 1
            switch escaped {
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case octalDigits:
                // Up to three octal digits.
                var value = UInt32(escaped - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, index < body.endIndex, octalDigits.contains(body[index]) {
                    value = value * 8 + UInt32(body[index] - UInt8(ascii: "0"))
                    digits += 1
                    index += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default:
                // Covers `\"` and `\\` too.
                bytes.append(escaped)
            }
        }
        return bytes
    }
}
