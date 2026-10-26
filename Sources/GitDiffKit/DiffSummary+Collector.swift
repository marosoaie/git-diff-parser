extension DiffSummary {
    /// Collects a ``DiffSummary`` from parser events.
    ///
    /// ```swift
    /// var parser = DiffEventParser(consumer: DiffSummary.Collector())
    /// while let chunk = readSomeBytes() { parser.consume(chunk) }
    /// let summary = parser.finalize().summary
    /// ```
    ///
    /// It counts lines without looking at their content, so the parser's
    /// default line cap is enough: a truncated line still counts once.
    public struct Collector: DiffEventConsumer, Sendable {
        /// The summary collected so far; complete once the parser is
        /// finalized.
        public private(set) var summary = DiffSummary()
        /// The open file, appended to `summary` when it ends, so a line
        /// updates two counters rather than an array element.
        private var file: File?

        /// Creates a collector with nothing collected.
        public init() {}

        /// Opens an entry for the file.
        public mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>) {
            endFile()
            file = File(header: header)
        }

        /// Counts an added or deleted line.
        public mutating func line(_ line: LineInfo, content: Span<UInt8>) {
            switch line.kind {
            case .addition: file?.addedLineCount += 1
            case .deletion: file?.deletedLineCount += 1
            case .context: break
            }
        }

        /// Records the open file.
        public mutating func endFile() {
            if let file {
                summary.files.append(file)
            }
            file = nil
        }

        /// Keeps the report.
        public mutating func damage(_ report: DamageReport) {
            summary.damage.append(report)
        }
    }
}
