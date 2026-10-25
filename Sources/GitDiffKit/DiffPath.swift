/// A path as git wrote it: the exact bytes, with any quoting undone.
///
/// Git paths are bytes, and a repository's file names need not be UTF-8,
/// so equality and hashing compare bytes. `string` decodes lossily, which
/// can make two different paths print alike.
struct DiffPath: Sendable, Hashable, CustomStringConvertible {
    var bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The path decoded as UTF-8, with invalid bytes replaced by U+FFFD.
    var string: String { String(decoding: bytes, as: UTF8.self) }

    var description: String { string }
}
