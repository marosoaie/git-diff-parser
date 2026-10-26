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

    /// The full model's options: the line cap raised to 64 MiB, since a
    /// collector that keeps content grows with it anyway. A finite cap
    /// still bounds the buffer a newline-free stream could fill.
    public static let fullModel = ParsingOptions(maximumLineLength: 64 << 20)
}
