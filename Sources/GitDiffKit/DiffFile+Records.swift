extension DiffFile {
    /// One hunk line; see `Storage` for where its content starts.
    struct LineRecord: Sendable {
        /// Meaningful only with `.hasOldNumber`, so any `Int`, however
        /// absurd, is kept exactly.
        var oldNumber: Int
        var newNumber: Int
        var contentEnd: Int
        var flags: LineFlags

        init(_ info: LineInfo, contentEnd: Int) {
            oldNumber = info.oldNumber ?? 0
            newNumber = info.newNumber ?? 0
            self.contentEnd = contentEnd
            var flags: LineFlags = switch info.kind {
            case .addition: .addition
            case .deletion: .deletion
            case .context: []
            }
            if info.oldNumber != nil { flags.insert(.hasOldNumber) }
            if info.newNumber != nil { flags.insert(.hasNewNumber) }
            if info.endsWithCarriageReturn { flags.insert(.endsWithCarriageReturn) }
            if info.isTruncated { flags.insert(.isTruncated) }
            self.flags = flags
        }

        var info: LineInfo {
            let kind: LineInfo.Kind = if flags.contains(.addition) {
                .addition
            } else if flags.contains(.deletion) {
                .deletion
            } else {
                .context
            }
            return LineInfo(
                kind: kind,
                oldNumber: flags.contains(.hasOldNumber) ? oldNumber : nil,
                newNumber: flags.contains(.hasNewNumber) ? newNumber : nil,
                endsWithCarriageReturn: flags.contains(.endsWithCarriageReturn),
                isTruncated: flags.contains(.isTruncated)
            )
        }
    }

    /// A hunk's lines and trailing lines run up to the next hunk's
    /// first ones, or to the end of their arrays for the last hunk.
    struct HunkRecord: Sendable {
        var header: HunkHeader
        var heading: Range<Int>
        var firstLine: Int
        var firstTrailingLine: Int
    }

    struct TextRecord: Sendable {
        var range: Range<Int>
        var endsWithCarriageReturn: Bool
    }

    /// A `LineRecord`'s kind and flags in one byte.
    struct LineFlags: OptionSet, Sendable {
        let rawValue: UInt8
        /// Neither this nor `.deletion` means context.
        static let addition = LineFlags(rawValue: 1 << 0)
        static let deletion = LineFlags(rawValue: 1 << 1)
        static let hasOldNumber = LineFlags(rawValue: 1 << 2)
        static let hasNewNumber = LineFlags(rawValue: 1 << 3)
        static let endsWithCarriageReturn = LineFlags(rawValue: 1 << 4)
        static let isTruncated = LineFlags(rawValue: 1 << 5)
        static let hasNoNewlineAtEnd = LineFlags(rawValue: 1 << 6)
    }
}
