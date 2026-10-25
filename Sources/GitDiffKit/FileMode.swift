/// A git file mode, such as `100644`, as written in a header.
///
/// The raw value is kept as written, not canonicalized the way `git apply`
/// does it, so a header renders back unchanged.
public struct FileMode: RawRepresentable, Sendable, Hashable {
    /// The mode's bits, such as `0o100644`.
    public var rawValue: UInt32

    /// Creates a mode from its bits.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// A regular file, `100644`.
    public static let regular = FileMode(rawValue: 0o100644)
    /// An executable file, `100755`.
    public static let executable = FileMode(rawValue: 0o100755)
    /// A symbolic link, `120000`.
    public static let symlink = FileMode(rawValue: 0o120000)
    /// A submodule, `160000`.
    public static let gitlink = FileMode(rawValue: 0o160000)

    /// Parses an octal mode that runs to the end of `text` or to a space
    /// or tab; nil for anything else, including a value over 32 bits.
    init?(octal text: ArraySlice<UInt8>) {
        let digits = text.prefix { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }
        guard !digits.isEmpty else { return nil }
        let value = digits.reduce(UInt32?.some(0)) { partial, byte in
            guard let partial, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) else { return nil }
            let (shifted, overflow) = partial.multipliedReportingOverflow(by: 8)
            return overflow ? nil : shifted | UInt32(byte - UInt8(ascii: "0"))
        }
        guard let value else { return nil }
        self.init(rawValue: value)
    }
}
