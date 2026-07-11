import Foundation

/// A streaming diagnostic extractor: feed it a log in arbitrary byte chunks
/// and call `finalize()` once at the end.
///
/// All parsers in this module ignore lines that don't look like diagnostics,
/// so raw tool output can be piped in unfiltered, and they collapse exact
/// duplicate diagnostics (xcodebuild frequently prints the same one per
/// architecture or target).
public protocol LogParsing {
    init()

    /// Feeds the next chunk of log bytes. Chunks may split lines — or
    /// multi-byte UTF-8 characters — anywhere.
    mutating func consume(_ chunk: ArraySlice<UInt8>)

    /// Flushes any unterminated final line and returns the diagnostics in
    /// log order.
    mutating func finalize() -> [Diagnostic]
}

extension LogParsing {
    public mutating func consume(_ chunk: [UInt8]) {
        consume(chunk[...])
    }

    public mutating func consume(_ chunk: Data) {
        consume([UInt8](chunk)[...])
    }

    public mutating func consume(_ text: String) {
        consume(Array(text.utf8)[...])
    }

    /// Parses a complete log held in memory. For large inputs, prefer
    /// feeding chunks to a parser instance instead.
    public static func diagnostics(in log: String) -> [Diagnostic] {
        var parser = Self()
        parser.consume(log)
        return parser.finalize()
    }
}
