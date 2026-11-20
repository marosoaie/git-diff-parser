/// The numbers of the lines a diff adds or modifies, grouped by file path.
///
/// Paths are as they appear on the "new" side of the diff (the `+++ b/...`
/// header), without git's `a/` or `b/` prefix: for `git diff`, relative to
/// the repository root. Deleted files never appear,
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
public struct ChangedLineNumbers: Sendable, Equatable {
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
    /// hold plain sets of line numbers. Entries whose set is empty are
    /// discarded, so `files` never contains files with no changed lines.
    public init(files: [String: Set<Int>]) {
        self.files = files
            .filter { !$0.value.isEmpty }
            .mapValues { lineNumbers in LineRangeSet(lineNumbers.sorted().map { $0...$0 }) }
    }

    /// Parses a complete unified diff held in memory. For large inputs,
    /// prefer streaming chunks through a ``DiffEventParser`` with a
    /// ``Collector``.
    public init(diff: String) {
        var parser = DiffEventParser(consumer: Collector())
        parser.consume(diff)
        self = parser.finalize().changedLineNumbers
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

    /// Whether the diff adds `line` to the file at `path`, or with a
    /// tolerance, any line within `tolerance` lines of it; a binary search.
    public func contains(line: Int, in path: String, tolerance: Int = 0) -> Bool {
        files[path]?.contains(line, tolerance: tolerance) ?? false
    }

    /// Adds a file's line numbers; a path seen before (a `git log -p`
    /// stream touches files repeatedly) gets the union.
    mutating func add(_ lineNumbers: LineRangeSet, to path: String) {
        guard !lineNumbers.isEmpty else { return }
        files[path, default: LineRangeSet()].formUnion(lineNumbers)
    }
}
