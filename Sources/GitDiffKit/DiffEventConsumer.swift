/// Receives a diff's structure as it streams past.
///
/// A `DiffEventParser` calls these in input order. Every method has an
/// empty default, so a consumer implements only what it needs. Span
/// arguments point into the parser's buffers and are valid only during the
/// call; keep them with `[UInt8](copying:)` or `String(decodingLossily:)`.
///
/// Ordering: `beginFile`, then hunks (`beginHunk` followed by `line`s) or
/// `binaryPatchLine`s, then `endFile`; every `beginFile` gets its
/// `endFile`. `noNewlineAtEndOfFile` comes only directly after a `line`.
/// `unrecognizedLine` and `damage` can come anywhere between those, and
/// `noNewlineAtEndOfInput` comes last, if at all.
///
/// Together the events carry the whole input, so a consumer that keeps
/// them can write it back, as the full model does with `Diff.render(_:)` —
/// except a combined diff's hunks, a damaged file's lines, the excess of
/// lines over the cap, and the wording of a localized
/// `\ No newline at end of file`.
public protocol DiffEventConsumer {
    /// A file's header block is complete (before its first hunk or binary
    /// data). `rawHeader` is the block verbatim, each line with its `\r`
    /// and `\n`, for round-tripping.
    mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>)
    /// A hunk starts; `heading` is the text after the closing `@@`,
    /// verbatim (usually a space and the enclosing function's signature),
    /// without the line's `\r`.
    mutating func beginHunk(_ header: HunkHeader, heading: Span<UInt8>)
    /// One hunk line; `content` excludes the marker column, the `\r`, and
    /// the terminator.
    mutating func line(_ line: LineInfo, content: Span<UInt8>)
    /// The previous line's side ends without a newline
    /// (`\ No newline at end of file`). The marker's text isn't kept: git
    /// writes it in English, GNU diff in the user's language.
    mutating func noNewlineAtEndOfFile(endsWithCarriageReturn: Bool)
    /// One line of a `GIT binary patch` block, after the marker line:
    /// `literal`/`delta` lines, base85 data, and the blank line ending
    /// each part. The data isn't decoded.
    mutating func binaryPatchLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool)
    /// The current file is over: the next file starts or input ends.
    mutating func endFile()
    /// A line that is neither header nor hunk content: a commit message,
    /// mail headers, `Only in …`, junk.
    mutating func unrecognizedLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool)
    /// The input was damaged: `.info` for a local recovery, `.error` for an
    /// abandoned file.
    mutating func damage(_ report: DamageReport)
    /// The input's last line has no `\n`: the input ended mid-line, as a
    /// diff whose final newline an editor or a shell's `$(…)` dropped does.
    /// Sent once, after every other event.
    mutating func noNewlineAtEndOfInput()
}

extension DiffEventConsumer {
    /// Ignores the event.
    public mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>) {}
    /// Ignores the event.
    public mutating func beginHunk(_ header: HunkHeader, heading: Span<UInt8>) {}
    /// Ignores the event.
    public mutating func line(_ line: LineInfo, content: Span<UInt8>) {}
    /// Ignores the event.
    public mutating func noNewlineAtEndOfFile(endsWithCarriageReturn: Bool) {}
    /// Ignores the event.
    public mutating func binaryPatchLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) {}
    /// Ignores the event.
    public mutating func endFile() {}
    /// Ignores the event.
    public mutating func unrecognizedLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) {}
    /// Ignores the event.
    public mutating func damage(_ report: DamageReport) {}
    /// Ignores the event.
    public mutating func noNewlineAtEndOfInput() {}
}
