/// One hunk of a file in the full model: its header, its section heading,
/// its lines, and any unrecognized lines that follow it.
public struct DiffHunk: Sendable, Equatable {
    /// The ranges the `@@` line declares.
    public var header: HunkHeader
    /// The text after the closing `@@`, verbatim: usually a space and the
    /// enclosing function's signature, or empty.
    public var heading: ArraySlice<UInt8>
    /// The hunk's lines, in order.
    public var lines: DiffFile.Lines
    /// Unrecognized lines after the hunk's lines, up to the next hunk or
    /// the end of the file: in `git log -p` output, the next commit's
    /// message follows the last hunk of the previous commit's last file.
    public var trailingLines: DiffFile.TextLines

    /// Creates a hunk from its parts.
    public init(
        header: HunkHeader,
        heading: ArraySlice<UInt8> = [],
        lines: DiffFile.Lines = [],
        trailingLines: DiffFile.TextLines = []
    ) {
        self.header = header
        self.heading = heading
        self.lines = lines
        self.trailingLines = trailingLines
    }
}
