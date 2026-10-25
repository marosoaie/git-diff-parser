/// Streaming parser for unified diffs as produced by `git diff` / `git show`.
///
/// Feed it the diff in arbitrary byte chunks (any size, split anywhere) and
/// call `finalize()` once at the end. Memory use is bounded by the size of the
/// *result* (one range per contiguous run of added lines), not by the size
/// of the input, so multi-hundred-megabyte diffs parse in constant working
/// memory.
///
///     var parser = DiffParser()
///     while let chunk = readSomeBytes() { parser.consume(chunk) }
///     let changes = parser.finalize()
///
/// The library doesn't depend on Foundation; feed `Data` read from a
/// `FileHandle` as `[UInt8](data)`.
///
/// A facade over `DiffEventParser` with a `ChangedLines.Collector`; use
/// those directly to see more of the diff than its added lines.
public struct DiffParser: Sendable {
    private var parser = DiffEventParser(consumer: ChangedLines.Collector())

    /// Creates a parser with no input consumed.
    public init() {}

    /// Feeds the next chunk of the diff; it may end mid-line.
    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        parser.consume(chunk)
    }

    /// Feeds the next chunk of the diff; it may end mid-line.
    public mutating func consume(_ chunk: [UInt8]) {
        parser.consume(chunk)
    }

    /// Feeds the next chunk of the diff as UTF-8 text; it may end mid-line.
    public mutating func consume(_ text: String) {
        parser.consume(text)
    }

    /// Flushes any unterminated final line and returns the result.
    public mutating func finalize() -> ChangedLines {
        parser.finalize().changedLines
    }
}

extension ChangedLines {
    /// Parses a complete unified diff held in memory. For large inputs,
    /// prefer feeding chunks to a `DiffParser` instead.
    public init(diff: String) {
        var parser = DiffParser()
        parser.consume(diff)
        self = parser.finalize()
    }
}
