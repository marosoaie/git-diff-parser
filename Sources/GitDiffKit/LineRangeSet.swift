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
    /// overlapping or not. It sorts them once and merges in one pass, so
    /// ranges in any order cost O(n log n); inserting them one by one
    /// costs O(n²) when they come in descending order.
    public init(_ unsorted: some Sequence<ClosedRange<Int>>) {
        ranges = unsorted.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, range in
            guard let last = merged.last, !Self.gapFollows(last.upperBound, before: range.lowerBound) else {
                return merged.append(range)
            }
            merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
        }
    }

    /// Wraps ranges that are already sorted, disjoint, and non-adjacent.
    init(normalized ranges: [ClosedRange<Int>]) {
        self.ranges = ranges
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

    /// Every covered line number, ascending. Beware: materializes the full
    /// list — fine for a PR-sized diff, wasteful for a huge one.
    public var allLineNumbers: [Int] {
        ranges.flatMap { Array($0) }
    }

    /// Adds `line`, merging it with the ranges it touches.
    public mutating func insert(_ line: Int) {
        insert(line...line)
    }

    /// Adds the lines of `range`, merging it with the ranges it overlaps
    /// or touches. A range starting at or past the last range's start
    /// inserts in O(1); one starting lower shifts the ranges after it, so
    /// for many ranges in any order, prefer ``init(_:)``.
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

    /// Adds every line of `other`: in O(m) when it starts at or past the
    /// last range, as a file seen again further down a log usually does,
    /// else by sorting both together.
    mutating func formUnion(_ other: LineRangeSet) {
        guard !isEmpty else {
            self = other
            return
        }
        if extendsCheaply(with: other) {
            other.ranges.forEach { insert($0) }
        } else {
            self = LineRangeSet(ranges + other.ranges)
        }
    }

    /// Whether `other` starts at or past the last range, so each of its
    /// ranges inserts in O(1).
    func extendsCheaply(with other: LineRangeSet) -> Bool {
        guard let last = ranges.last, let first = other.ranges.first else { return true }
        return first.lowerBound >= last.lowerBound
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
