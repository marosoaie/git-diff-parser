extension ChangedLines {
    /// Collects the lines a diff adds, per file, from parser events: the
    /// consumer behind `DiffParser` and `ChangedLines(diff:)`.
    ///
    ///     var parser = DiffEventParser(consumer: ChangedLines.Collector())
    ///     parser.consume(diffBytes)
    ///     let changes = parser.finalize().changedLines
    ///
    /// A file's lines are recorded under its new path; deleted files have
    /// none, and combined diffs send no line events, so they add nothing.
    public struct Collector: DiffEventConsumer, Sendable {
        /// The lines collected so far; complete once the parser is
        /// finalized.
        public private(set) var changedLines = ChangedLines()
        /// The current file's new path, decoded once per file.
        private var path: String?
        /// The current file's lines, merged into `changedLines` when it
        /// ends, so the path is hashed once per file rather than per line.
        private var lines = LineRangeSet()

        /// Creates a collector with nothing collected.
        public init() {}

        /// Starts collecting under the file's new path.
        public mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>) {
            path = header.newPath?.string
        }

        /// Records an added line.
        public mutating func line(_ line: LineInfo, content: Span<UInt8>) {
            guard line.kind == .addition, let number = line.newNumber, path != nil else { return }
            lines.insert(number)
        }

        /// Records the file's lines.
        public mutating func endFile() {
            if let path {
                changedLines.add(lines, to: path)
            }
            path = nil
            lines = LineRangeSet()
        }
    }
}
