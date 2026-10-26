/// A compact set of line numbers, stored as sorted, disjoint, non-adjacent
/// closed ranges.
///
/// Diff hunks produce long runs of consecutive added lines, so ranges keep
/// memory bounded by the number of *edits* rather than the number of *lines*:
/// a wholesale 100k-line file rewrite is a single range.
public struct LineRangeSet: Sendable, Equatable {
    /// The covered lines as closed ranges, ascending, with a gap of at
    /// least one line between neighbors.
    public private(set) var ranges: [ClosedRange<Int>] = []

    /// Creates an empty set.
    public init() {}

    /// Creates a set of the lines `unsorted` covers, in any order and
    /// overlapping or not.
    public init(_ unsorted: some Sequence<ClosedRange<Int>>) {
        for range in unsorted { insert(range) }
    }

    /// Whether the set covers no lines.
    public var isEmpty: Bool { ranges.isEmpty }

    /// Total number of lines covered, saturating at `Int.max` for ranges too
    /// large to count.
    public var lineCount: Int {
        ranges.reduce(0) { total, range in
            let span = range.upperBound.subtractingReportingOverflow(range.lowerBound)
            guard !span.overflow, span.partialValue < Int.max else { return Int.max }
            let sum = total.addingReportingOverflow(span.partialValue + 1)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }

    /// Every covered line, ascending. Beware: materializes the full list —
    /// fine for a PR-sized diff, wasteful for a huge one.
    public var allLines: [Int] {
        ranges.flatMap { Array($0) }
    }

    /// Adds `line`, merging it with the ranges it touches.
    public mutating func insert(_ line: Int) {
        insert(line...line)
    }

    /// Adds the lines of `range`, merging it with the ranges it overlaps
    /// or touches.
    public mutating func insert(_ range: ClosedRange<Int>) {
        guard let last = ranges.last else {
            ranges.append(range)
            return
        }
        // Fast paths: diff parsing inserts in ascending order, so almost
        // every insert lands at or just past the tail. `gapFollows` is the
        // overflow-safe form of `lowerBound > upperBound + 1`.
        if Self.gapFollows(last.upperBound, before: range.lowerBound) {
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
            if Self.gapFollows(ranges[mid].upperBound, before: range.lowerBound) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var newLower = range.lowerBound
        var newUpper = range.upperBound
        var end = lo
        while end < ranges.count, !Self.gapFollows(newUpper, before: ranges[end].lowerBound) {
            newLower = min(newLower, ranges[end].lowerBound)
            newUpper = max(newUpper, ranges[end].upperBound)
            end += 1
        }
        ranges.replaceSubrange(lo..<end, with: [newLower...newUpper])
    }

    /// Adds every line of `other`.
    mutating func formUnion(_ other: LineRangeSet) {
        guard !isEmpty else {
            self = other
            return
        }
        other.ranges.forEach { insert($0) }
    }

    /// Whether `next` starts strictly beyond `upperBound + 1`, without
    /// overflowing when `upperBound` is `Int.max`.
    private static func gapFollows(_ upperBound: Int, before next: Int) -> Bool {
        upperBound < Int.max && next > upperBound + 1
    }

    /// Binary-search membership test. With a tolerance, matches any line
    /// within `tolerance` lines of a covered line. Negative tolerances are
    /// treated as zero.
    public func contains(_ line: Int, tolerance: Int = 0) -> Bool {
        let tolerance = max(0, tolerance)
        var lo = 0
        var hi = ranges.count
        // Overflow-checked bounds: saturate instead of trapping at the
        // extremes of Int.
        let low = line.subtractingReportingOverflow(tolerance)
        let lowestAcceptableUpper = low.overflow ? Int.min : low.partialValue
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound < lowestAcceptableUpper {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        guard lo < ranges.count else { return false }
        let bound = ranges[lo].lowerBound.subtractingReportingOverflow(tolerance)
        return bound.overflow || bound.partialValue <= line
    }
}

/// The lines a diff adds or modifies, grouped by file path.
///
/// Paths are as they appear on the "new" side of the diff (the `+++ b/...`
/// header), relative to the repository root. Deleted files never appear,
/// and only added lines are recorded: git represents a modified line as a
/// removal plus an addition, so additions cover both cases.
///
/// Keys are `String`s, decoded lossily from git's path bytes, and compare
/// by Unicode canonical equivalence: the NFC and NFD spellings of one name,
/// which git treats as two different paths, share a key.
///
/// Combined diffs of merges (`diff --cc`) are skipped and contribute no
/// lines; for the lines a merge changed, diff it against its first parent
/// (`--diff-merges=first-parent`) or use a three-dot diff.
public struct ChangedLines: Sendable, Equatable {
    /// Each file's added lines, keyed by its new path; a file with no
    /// added lines has no entry.
    public private(set) var files: [String: LineRangeSet] = [:]

    /// Creates a value with no files.
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

    /// Whether no file has added lines.
    public var isEmpty: Bool { files.isEmpty }

    /// File paths in a stable, sorted order.
    public var sortedPaths: [String] { files.keys.sorted() }

    /// The added lines of the file at `path`, as ascending ranges; empty
    /// for a file the diff adds no lines to.
    public func ranges(in path: String) -> [ClosedRange<Int>] {
        files[path]?.ranges ?? []
    }

    /// Expanded line list for one file — convenient for PR-sized diffs,
    /// wasteful for huge ones (prefer `ranges(in:)`).
    public func lines(in path: String) -> [Int] {
        files[path]?.allLines ?? []
    }

    /// Whether the diff adds `line` to the file at `path`, or with a
    /// tolerance, any line within `tolerance` lines of it; a binary search.
    public func contains(line: Int, in path: String, tolerance: Int = 0) -> Bool {
        files[path]?.contains(line, tolerance: tolerance) ?? false
    }

    /// Adds a file's lines; a path seen before (a `git log -p` stream
    /// touches files repeatedly) gets the union.
    mutating func add(_ lines: LineRangeSet, to path: String) {
        guard !lines.isEmpty else { return }
        files[path, default: LineRangeSet()].formUnion(lines)
    }
}
