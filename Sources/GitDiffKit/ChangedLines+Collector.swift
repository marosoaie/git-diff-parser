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
    ///
    /// Lines in any order cost O(n log n) in all: hunks that run backwards
    /// are sorted once when their file ends, and a path seen again below
    /// its earlier lines is merged in batches, so a hostile diff can't
    /// make the collector quadratic.
    public struct Collector: DiffEventConsumer, Sendable {
        /// The lines collected so far; complete once the parser is
        /// finalized.
        public var changedLines: ChangedLines {
            deferred.reduce(into: collected) { changes, entry in
                changes.add(LineRangeSet(entry.value), to: entry.key)
            }
        }

        /// Every file's lines but those in `deferred`.
        private var collected = ChangedLines()
        /// Lines of paths seen before that start below their last range,
        /// kept until a path has as many as it has ranges, then merged in
        /// one sort: merging each file as it ends would shift the path's
        /// ranges every time.
        private var deferred: [String: [ClosedRange<Int>]] = [:]
        /// The current file's new path, decoded once per file.
        private var path: String?
        /// The current file's lines as runs, in arrival order; recorded when
        /// it ends, so the path is hashed once per file rather than per line.
        private var runs: [ClosedRange<Int>] = []
        /// Whether every run starts past the one before, as hunks in order
        /// make them.
        private var runsAreSorted = true

        /// Creates a collector with nothing collected.
        public init() {}

        /// Starts collecting under the file's new path.
        public mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>) {
            path = header.newPath?.string
        }

        /// Records an added line.
        public mutating func line(_ line: LineInfo, content: Span<UInt8>) {
            guard line.kind == .addition, let number = line.newNumber, path != nil else { return }
            // Line numbers are at most 2⁴⁹, so `+ 1` can't overflow.
            if let last = runs.last {
                if number == last.upperBound + 1 {
                    runs[runs.count - 1] = last.lowerBound...number
                    return
                }
                if number <= last.upperBound {
                    runsAreSorted = false
                }
            }
            runs.append(number...number)
        }

        /// Records the file's lines.
        public mutating func endFile() {
            if let path, !runs.isEmpty {
                record(runsAreSorted ? LineRangeSet(normalized: runs) : LineRangeSet(runs), under: path)
            }
            path = nil
            runs = []
            runsAreSorted = true
        }

        private mutating func record(_ lines: LineRangeSet, under path: String) {
            guard let rangeCount = rangeCountIfMergingIsCostly(lines, under: path) else {
                return collected.add(lines, to: path)
            }
            deferred[path, default: []].append(contentsOf: lines.ranges)
            if let pending = deferred[path], pending.count >= rangeCount {
                deferred[path] = nil
                collected.add(LineRangeSet(pending), to: path)
            }
        }

        /// How many ranges `path` has, if merging `lines` into them would
        /// shift them; nil for a new path or lines that extend it cheaply.
        /// Apart from `record`, so no copy of the path's ranges outlives the
        /// check and makes the merge copy them.
        private func rangeCountIfMergingIsCostly(_ lines: LineRangeSet, under path: String) -> Int? {
            guard let existing = collected.files[path], !existing.extendsCheaply(with: lines) else { return nil }
            return existing.ranges.count
        }
    }
}
