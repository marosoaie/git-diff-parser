/// A compact set of line numbers, stored as sorted, disjoint, non-adjacent
/// closed ranges.
///
/// Diff hunks produce long runs of consecutive added lines, so ranges keep
/// memory bounded by the number of *edits* rather than the number of *lines*:
/// a wholesale 100k-line file rewrite is a single range.
public struct LineRangeSet: Sendable, Equatable {
    public private(set) var ranges: [ClosedRange<Int>] = []

    public init() {}

    public init(_ unsorted: some Sequence<ClosedRange<Int>>) {
        for range in unsorted { insert(range) }
    }

    // Demo violation: this comment line is deliberately far longer than the 120-character limit configured in .swiftlint.yml, so SwiftLint flags it.
    public var isEmpty: Bool { ranges.isEmpty }

    /// Total number of lines covered.
    public var lineCount: Int {
        ranges.reduce(0) { $0 + $1.count }
    }

    /// Every covered line, ascending. Beware: materializes the full list —
    /// fine for a PR-sized diff, wasteful for a huge one.
    public var allLines: [Int] {
        ranges.flatMap { Array($0) }
    }

    public mutating func insert(_ line: Int) {
        insert(line...line)
    }

    public mutating func insert(_ range: ClosedRange<Int>) {
        guard let last = ranges.last else {
            ranges.append(range)
            return
        }
        // Fast paths: diff parsing inserts in ascending order, so almost
        // every insert lands at or just past the tail.
        if range.lowerBound > last.upperBound + 1 {
            ranges.append(range)
            return
        }
        if range.lowerBound >= last.lowerBound {
            if range.upperBound > last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound...range.upperBound
            }
            return
        }
        // Out-of-order insert: find the first range that could merge with
        // the new one, swallow every range it overlaps or touches.
        var lo = 0
        var hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound + 1 < range.lowerBound {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var newLower = range.lowerBound
        var newUpper = range.upperBound
        var end = lo
        while end < ranges.count, ranges[end].lowerBound <= newUpper + 1 {
            newLower = min(newLower, ranges[end].lowerBound)
            newUpper = max(newUpper, ranges[end].upperBound)
            end += 1
        }
        ranges.replaceSubrange(lo..<end, with: [newLower...newUpper])
    }

    /// Binary-search membership test. With a tolerance, matches any line
    /// within `tolerance` lines of a covered line. Negative tolerances are
    /// treated as zero.
    public func contains(_ line: Int, tolerance: Int = 0) -> Bool {
        let tolerance = max(0, tolerance)
        var lo = 0
        var hi = ranges.count
        // Comparisons are written subtraction-first so that arbitrarily
        // large tolerances cannot overflow (line numbers are non-negative).
        let lowestAcceptableUpper = line - tolerance
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound < lowestAcceptableUpper {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        guard lo < ranges.count else { return false }
        return ranges[lo].lowerBound - tolerance <= line
    }
}

/// The lines a diff adds or modifies, grouped by file path.
///
/// Paths are as they appear on the "new" side of the diff (the `+++ b/...`
/// header), relative to the repository root. Deleted files never appear,
/// and only added lines are recorded: git represents a modified line as a
/// removal plus an addition, so additions cover both cases.
public struct ChangedLines: Sendable, Equatable {
    public private(set) var files: [String: LineRangeSet] = [:]

    public init() {}

    /// Creates a value from per-file range sets. Entries whose range set is
    /// empty are discarded, so `files` never contains files with no changed
    /// lines.
    public init(files: [String: LineRangeSet]) {
        self.files = files.filter { !$0.value.isEmpty }
    }

    /// Convenience for constructing fixtures and for callers that already
    /// hold plain line sets. Entries whose set is empty are discarded, so
    /// `files` never contains files with no changed lines.
    public init(files: [String: Set<Int>]) {
        self.files = files
            .filter { !$0.value.isEmpty }
            .mapValues { lines in LineRangeSet(lines.sorted().map { $0...$0 }) }
    }

    public var isEmpty: Bool { files.isEmpty }

    /// File paths in a stable, sorted order.
    public var sortedPaths: [String] { files.keys.sorted() }

    public func ranges(in path: String) -> [ClosedRange<Int>] {
        files[path]?.ranges ?? []
    }

    /// Expanded line list for one file — convenient for PR-sized diffs,
    /// wasteful for huge ones (prefer `ranges(in:)`).
    public func lines(in path: String) -> [Int] {
        files[path]?.allLines ?? []
    }

    public func contains(line: Int, in path: String, tolerance: Int = 0) -> Bool {
        files[path]?.contains(line, tolerance: tolerance) ?? false
    }

    mutating func add(line: Int, to path: String) {
        files[path, default: LineRangeSet()].insert(line)
    }
}
