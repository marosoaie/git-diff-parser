/// One edit of a diff: the original bytes `range` replaced by
/// `replacement`.
struct Mutation: Equatable, CustomStringConvertible {
    /// How the edit was chosen; see `random(in:using:)`.
    enum Kind: String, CaseIterable {
        case byteReplaced
        case bytesInserted
        case bytesDeleted
        case truncated
        case linesDuplicated
        case lineRepeated
        case linesDropped
        case linesSwapped
        case lineCopied
        case hunkCountChanged
        case atSignsChanged
        case markerReplaced
        case carriageReturnAdded
        case newlineRemoved
    }

    var kind: Kind
    var range: Range<Int>
    var replacement: [UInt8]

    /// Short on purpose: it goes into failure messages, never the bytes of
    /// a long replacement.
    var description: String {
        let shown = replacement.prefix(24).map { String(decoding: [$0], as: UTF8.self) }.joined()
        let more = replacement.count > 24 ? "… (\(replacement.count) bytes)" : ""
        return "\(kind) of bytes \(range) with \(shown.debugDescription)\(more)"
    }

    func applied(to bytes: [UInt8]) -> [UInt8] {
        var copy = bytes
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}
