/// A line the full model keeps verbatim: one of a `GIT binary patch`
/// block, or an unrecognized line such as a commit message.
public struct DiffTextLine: Sendable, Equatable {
    /// The line's bytes, without the `\r` or the terminator.
    public var content: ArraySlice<UInt8>
    /// Whether the line ended in `\r\n`.
    public var endsWithCarriageReturn: Bool

    /// Creates a line from its parts.
    public init(content: ArraySlice<UInt8>, endsWithCarriageReturn: Bool = false) {
        self.content = content
        self.endsWithCarriageReturn = endsWithCarriageReturn
    }
}
