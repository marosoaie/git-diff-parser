/// One line of a hunk in the full model: what it is, where it sits, and its
/// content.
///
/// A `DiffFile` stores its lines packed and hands out `DiffLine` values on
/// access; `content` is a slice of the file's storage.
public struct DiffLine: Sendable, Equatable {
    /// Which side the line belongs to, its old and new numbers, and its
    /// `\r` and truncation flags.
    public var info: LineInfo
    /// The line's bytes, without the marker column, the `\r`, or the
    /// terminator.
    public var content: ArraySlice<UInt8>
    /// Whether a `\ No newline at end of file` line followed it: the line
    /// ends its side's file without a newline.
    public var hasNoNewlineAtEnd: Bool
    /// Whether that `\ No newline at end of file` line ended in `\r\n`, as
    /// in a diff stored with CRLF line endings; git writes it with `\n`.
    public var noNewlineMarkerEndsWithCarriageReturn: Bool

    /// Creates a line from its parts.
    public init(
        info: LineInfo,
        content: ArraySlice<UInt8>,
        hasNoNewlineAtEnd: Bool = false,
        noNewlineMarkerEndsWithCarriageReturn: Bool = false
    ) {
        self.info = info
        self.content = content
        self.hasNoNewlineAtEnd = hasNoNewlineAtEnd
        self.noNewlineMarkerEndsWithCarriageReturn = noNewlineMarkerEndsWithCarriageReturn
    }
}
