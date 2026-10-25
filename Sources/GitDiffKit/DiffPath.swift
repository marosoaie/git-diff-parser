/// A path as git wrote it: the exact bytes, with any quoting undone.
///
/// Git paths are bytes, and a repository's file names need not be UTF-8,
/// so equality and hashing compare bytes. `string` decodes lossily, which
/// can make two different paths print alike.
public struct DiffPath: Sendable, Hashable, CustomStringConvertible {
    /// The path's bytes, unquoted, without git's `a/` or `b/` prefix.
    public var bytes: [UInt8]

    /// Creates a path from its unquoted bytes.
    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The path decoded as UTF-8, with invalid bytes replaced by U+FFFD.
    public var string: String { String(decoding: bytes, as: UTF8.self) }

    /// The path as `string` decodes it.
    public var description: String { string }
}
