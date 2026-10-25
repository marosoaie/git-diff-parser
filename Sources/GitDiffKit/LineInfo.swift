/// What a hunk line is and where it sits, without its content.
public struct LineInfo: Sendable, Equatable {
    /// Which side of the diff a hunk line belongs to.
    public enum Kind: Sendable, Equatable {
        /// Unchanged: on both sides (` `, or a line with no marker at all).
        case context
        /// Only on the new side (`+`).
        case addition
        /// Only on the old side (`-`).
        case deletion
    }

    /// Which side of the diff the line belongs to.
    public var kind: Kind
    /// The line's number in the old file; nil for an addition.
    public var oldNumber: Int?
    /// The line's number in the new file; nil for a deletion.
    public var newNumber: Int?
    /// Whether the line ended in `\r\n`. The `\r` is not part of the
    /// content, so CRLF diffs parse like LF ones; this flag renders it back.
    public var endsWithCarriageReturn: Bool
    /// Whether the line was longer than `ParsingOptions.maximumLineLength`
    /// and was cut to that many bytes; the cap counts the marker column, so
    /// the content keeps one byte less.
    public var isTruncated: Bool

    /// Creates line information from its parts.
    public init(
        kind: Kind,
        oldNumber: Int?,
        newNumber: Int?,
        endsWithCarriageReturn: Bool = false,
        isTruncated: Bool = false
    ) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.endsWithCarriageReturn = endsWithCarriageReturn
        self.isTruncated = isTruncated
    }
}
