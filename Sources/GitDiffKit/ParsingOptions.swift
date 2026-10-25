/// Settings for a `DiffEventParser`.
public struct ParsingOptions: Sendable, Equatable {
    /// The longest line the parser hands on, in bytes, not counting its
    /// terminator or a trailing `\r`; longer lines are cut to it and flagged
    /// `isTruncated`. Bounds the buffer that carries a line across chunks,
    /// so a newline-free stream can't grow memory. Defaults to 1 MiB; a
    /// negative value acts as zero.
    public var maximumLineLength: Int

    /// Creates options with the given line cap.
    public init(maximumLineLength: Int = 1 << 20) {
        self.maximumLineLength = maximumLineLength
    }
}
