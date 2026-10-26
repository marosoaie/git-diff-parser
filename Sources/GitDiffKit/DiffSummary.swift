/// Each file a diff touches, with its header and how many lines it adds and
/// deletes: what `git apply --summary` and `--numstat` report.
///
///     let summary = DiffSummary(diff: diffText)
///     summary.files.map { ($0.header.newPath, $0.addedLineCount) }
///
/// Memory grows with the number of files, not with the diff's content, so
/// it suits diffs of any size; stream large ones through a
/// `DiffEventParser` with a `DiffSummary.Collector`.
///
/// Files come in input order. A file abandoned as damaged is missing, and
/// its `DamageReport` is in `damage`. Combined diffs of merges are listed
/// with format `.combined` and no line counts, because their hunks are
/// skipped (see `FileHeader.Format.combined`).
public struct DiffSummary: Sendable, Equatable {
    /// One file of the diff.
    public struct File: Sendable, Equatable {
        /// What the diff says about the file: status, paths, modes, and
        /// whether it is binary.
        public var header: FileHeader
        /// How many lines the file's hunks add; 0 for a binary file, whose
        /// changes have no lines.
        public var addedLineCount: Int
        /// How many lines the file's hunks delete; 0 for a binary file.
        public var deletedLineCount: Int

        /// Creates a file entry from its parts.
        public init(header: FileHeader, addedLineCount: Int = 0, deletedLineCount: Int = 0) {
            self.header = header
            self.addedLineCount = addedLineCount
            self.deletedLineCount = deletedLineCount
        }
    }

    /// The diff's files, in input order.
    public var files: [File]
    /// Every damage report the parser made, in input order. Hostile input
    /// can produce one per line, so on untrusted input this list, unlike
    /// `files`, can grow with the input.
    public var damage: [DamageReport]

    /// Creates a summary from its parts.
    public init(files: [File] = [], damage: [DamageReport] = []) {
        self.files = files
        self.damage = damage
    }

    /// Summarizes a complete diff held in memory. For large inputs, prefer
    /// streaming chunks through a `DiffEventParser` with a `Collector`.
    public init(diff: String) {
        var parser = DiffEventParser(consumer: Collector())
        parser.consume(diff)
        self = parser.finalize().summary
    }

    /// Summarizes a complete diff held in memory as bytes, which needn't be
    /// valid UTF-8.
    public init(diff: [UInt8]) {
        var parser = DiffEventParser(consumer: Collector())
        parser.consume(diff)
        self = parser.finalize().summary
    }
}
