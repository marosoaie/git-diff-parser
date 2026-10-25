/// Everything a diff says about one file before its hunks: what changed
/// about it, its paths, modes, and object IDs.
///
/// Built from the file's header block by `FileHeaderParser`. Paths follow
/// a precedence, because `diff --git a/x b/y` is ambiguous when unquoted
/// paths contain spaces: `rename`/`copy from`/`to` first, then
/// `---`/`+++`, then the `diff --git` line, split where both names match.
struct FileHeader: Sendable, Equatable {
    /// Which kind of diff the file came from.
    enum Format: Sendable, Equatable {
        /// `diff --git`, with extended headers.
        case git
        /// `diff --cc` or `diff --combined`, a merge against `parents`
        /// parents. Recognized and skipped in 0.2 (D9).
        case combined(parents: Int)
        /// Plain `diff -u` output: `---`/`+++` with no extended headers.
        case unified
    }

    var format: Format
    var change: Change
    /// Nil for a creation, and when the header names no usable old path.
    var oldPath: DiffPath?
    /// Nil for a deletion, and when the header names no usable new path.
    var newPath: DiffPath?
    var oldMode: FileMode?
    var newMode: FileMode?
    /// From the `index` line: abbreviated, or full with `--full-index` or
    /// `--binary`. All zeros for the missing side of a creation or deletion.
    var oldObjectID: ObjectID?
    var newObjectID: ObjectID?
    /// The `dissimilarity index` percentage of a rewrite (`-B`).
    var dissimilarity: Int?
    /// Set by `Binary files … differ` and `GIT binary patch`.
    var isBinary: Bool

    init(
        format: Format,
        change: Change,
        oldPath: DiffPath? = nil,
        newPath: DiffPath? = nil,
        oldMode: FileMode? = nil,
        newMode: FileMode? = nil,
        oldObjectID: ObjectID? = nil,
        newObjectID: ObjectID? = nil,
        dissimilarity: Int? = nil,
        isBinary: Bool = false
    ) {
        self.format = format
        self.change = change
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldMode = oldMode
        self.newMode = newMode
        self.oldObjectID = oldObjectID
        self.newObjectID = newObjectID
        self.dissimilarity = dissimilarity
        self.isBinary = isBinary
    }

    /// Whether both modes are known and differ. A creation or deletion is
    /// never a mode change, though it has a mode on one side.
    var modeChanged: Bool {
        guard let oldMode, let newMode, change != .added, change != .deleted else { return false }
        return oldMode != newMode
    }
}
