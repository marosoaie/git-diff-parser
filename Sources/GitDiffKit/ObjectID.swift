/// A hex object ID from an `index` line, abbreviated or full, SHA-1 or
/// SHA-256.
///
/// Up to 64 hex digits are stored inline as nibbles, so an ID never
/// allocates. Hex is case-insensitive; `description` prints lowercase.
struct ObjectID: Sendable, Hashable, CustomStringConvertible {
    /// SHA-256's length; SHA-1 IDs have 40 digits.
    static let maximumHexDigits = 64

    // 64 nibbles in four words, most significant nibble first. Stored
    // properties rather than a tuple keep Hashable synthesized.
    private var word0: UInt64 = 0
    private var word1: UInt64 = 0
    private var word2: UInt64 = 0
    private var word3: UInt64 = 0
    /// How many hex digits the header wrote.
    private(set) var hexDigitCount: Int

    /// Parses 1 to 64 hex digits; nil for anything else.
    init?(hex: ArraySlice<UInt8>) {
        guard (1...Self.maximumHexDigits).contains(hex.count) else { return nil }
        let nibbles = hex.compactMap(Self.nibble)
        guard nibbles.count == hex.count else { return nil }
        hexDigitCount = nibbles.count
        nibbles.enumerated().forEach { offset, nibble in
            let bits = UInt64(nibble) << Self.shift(of: offset)
            switch offset / 16 {
            case 0: word0 |= bits
            case 1: word1 |= bits
            case 2: word2 |= bits
            default: word3 |= bits
            }
        }
    }

    /// Whether every digit is zero, git's spelling of "no object" (the old
    /// side of a creation, the new side of a deletion).
    var isZero: Bool { word0 | word1 | word2 | word3 == 0 }

    var description: String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: (0..<hexDigitCount).map { digits[Int(nibble(at: $0))] }, as: UTF8.self)
    }

    private func nibble(at offset: Int) -> UInt64 {
        let word = switch offset / 16 {
        case 0: word0
        case 1: word1
        case 2: word2
        default: word3
        }
        return (word >> Self.shift(of: offset)) & 0xF
    }

    private static func shift(of offset: Int) -> UInt64 {
        UInt64(15 - offset % 16) * 4
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
