/// Everything a diff says about one file before its hunks: what changed
/// about it, its paths, modes, and object IDs.
///
/// Assembled from the file's header block. Paths follow
/// a precedence, because `diff --git a/x b/y` is ambiguous when unquoted
/// paths contain spaces: `rename`/`copy from`/`to` first, then
/// `---`/`+++`, then the `diff --git` line, split where both names match.
public struct FileHeader: Sendable, Equatable {
    /// Which kind of diff the file came from.
    public enum Format: Sendable, Equatable {
        /// `diff --git`, with extended headers.
        case git
        /// `diff --cc` or `diff --combined`, a merge against `parents`
        /// parents. Recognized and skipped: only the result side of
        /// the header is parsed (new path, mode, and object ID), and its
        /// hunks produce no line events. For the lines a merge changed,
        /// diff against its first parent (`--diff-merges=first-parent`).
        case combined(parents: Int)
        /// Plain `diff -u` output: `---`/`+++` with no extended headers.
        case unified
    }

    /// Which kind of diff the file came from.
    public var format: Format
    /// What the diff does to the file's identity.
    public var change: Change
    /// Nil for a creation, and when the header names no usable old path.
    public var oldPath: DiffPath?
    /// Nil for a deletion, and when the header names no usable new path.
    public var newPath: DiffPath?
    /// The old side's mode: from `old mode`, `deleted file mode`, or the
    /// `index` line's trailer; nil for a creation or when no line says.
    public var oldMode: FileMode?
    /// The new side's mode: from `new mode`, `new file mode`, or the
    /// `index` line's trailer; nil for a deletion or when no line says.
    public var newMode: FileMode?
    /// The old side's object ID, from the `index` line: abbreviated, or
    /// full with `--full-index` or `--binary`. All zeros for the missing
    /// side of a creation or deletion.
    public var oldObjectID: ObjectID?
    /// The new side's object ID, from the `index` line.
    public var newObjectID: ObjectID?
    /// The `dissimilarity index` percentage of a rewrite (`-B`).
    public var dissimilarity: Int?
    /// Set by `Binary files … differ` and `GIT binary patch`.
    public var isBinary: Bool

    /// Creates a header from its parts.
    public init(
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
    public var modeChanged: Bool {
        guard let oldMode, let newMode, change != .added, change != .deleted else { return false }
        return oldMode != newMode
    }
}
