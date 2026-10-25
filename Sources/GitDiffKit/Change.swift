/// What a diff does to a file's identity: creates, deletes, keeps, renames,
/// or copies it.
///
/// Orthogonal to content changes, mode changes, and binary-ness, which
/// `FileHeader` records separately: a rename can also edit the file.
public enum Change: Sendable, Equatable {
    /// The file is created (`new file mode`, or `--- /dev/null`).
    case added
    /// The file is deleted (`deleted file mode`, or `+++ /dev/null`).
    case deleted
    /// The file keeps its path; its content or mode may change.
    case modified
    /// The file moves from `oldPath` to `newPath` (`rename from`/`to`).
    ///
    /// `similarity` is the header's percentage, nil when it is missing or
    /// over 100 (which `git apply` ignores too).
    case renamed(similarity: Int?)
    /// `newPath` is a copy of `oldPath` (`copy from`/`to`), which stays.
    ///
    /// `similarity` as for `renamed`.
    case copied(similarity: Int?)
}
