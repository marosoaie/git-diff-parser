/// What a diff does to a file's identity: creates, deletes, keeps, renames,
/// or copies it.
///
/// Orthogonal to content changes, mode changes, and binary-ness, which
/// `FileHeader` records separately: a rename can also edit the file.
enum Change: Sendable, Equatable {
    case added
    case deleted
    case modified
    /// `similarity` is the header's percentage, nil when it is missing or
    /// over 100 (which `git apply` ignores too).
    case renamed(similarity: Int?)
    /// `similarity` as for `renamed`.
    case copied(similarity: Int?)
}
