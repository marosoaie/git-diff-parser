extension DiffFile {
    /// Hunk lines, in order, read from a file's packed storage: a hunk's
    /// lines, or all of a file's.
    ///
    /// Indices run from 0 to `count`, whichever lines the collection holds.
    /// Elements are built on access and share the file's storage.
    public struct Lines: RandomAccessCollection, ExpressibleByArrayLiteral, Sendable, Equatable,
        CustomStringConvertible, CustomReflectable {
        private let bytes: [UInt8]
        private let records: [LineRecord]
        /// Where these lines start in `records`.
        private let offset: Int
        /// The number of lines.
        public let endIndex: Int

        init(of storage: Storage, range: Range<Int>) {
            bytes = storage.lineBytes
            records = storage.lines
            offset = range.lowerBound
            endIndex = range.count
        }

        /// Creates a collection holding copies of `lines`, packed.
        public init(_ lines: some Sequence<DiffLine>) {
            var storage = Storage()
            lines.forEach { storage.append($0) }
            self.init(of: storage, range: storage.lines.indices)
        }

        /// Creates a collection holding copies of `elements`, packed.
        public init(arrayLiteral elements: DiffLine...) {
            self.init(elements)
        }

        /// Always 0.
        public var startIndex: Int { 0 }

        /// The line at `position`, which must be in `indices`.
        public subscript(position: Int) -> DiffLine {
            precondition(indices.contains(position), "DiffFile.Lines index out of range")
            let index = offset + position
            let record = records[index]
            let start = index == 0 ? 0 : records[index - 1].contentEnd
            return DiffLine(
                info: record.info,
                content: bytes[start..<record.contentEnd],
                hasNoNewlineAtEnd: record.flags.contains(.hasNoNewlineAtEnd)
            )
        }

        /// Whether both hold equal lines in the same order, however they are
        /// stored.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.elementsEqual(rhs)
        }

        /// The lines, printed as an array is.
        public var description: String {
            Array(self).description
        }

        /// The lines, so `dump` and debuggers show them rather than the
        /// packed storage.
        public var customMirror: Mirror {
            Mirror(self, unlabeledChildren: Array(self), displayStyle: .collection)
        }
    }
}
