extension DiffFile {
    /// Lines kept verbatim, in order: a file's binary patch lines, its
    /// leading lines, a hunk's trailing lines, or a diff's preamble.
    ///
    /// Indices run from 0 to `count`. Elements are built on access and
    /// share the storage they come from.
    public struct TextLines: RandomAccessCollection, ExpressibleByArrayLiteral, Sendable, Equatable,
        CustomStringConvertible, CustomReflectable {
        private var bytes: [UInt8]
        private var records: [TextRecord]
        /// Where these lines start in `records`.
        private let offset: Int
        /// The number of lines.
        public private(set) var endIndex: Int

        init(bytes: [UInt8], records: [TextRecord], range: Range<Int>) {
            self.bytes = bytes
            self.records = records
            offset = range.lowerBound
            endIndex = range.count
        }

        /// Creates a collection holding copies of `lines`, packed.
        public init(_ lines: some Sequence<DiffTextLine>) {
            self.init(bytes: [], records: [], range: 0..<0)
            lines.forEach { line in
                let content = line.content
                append(content.span, endsWithCarriageReturn: line.endsWithCarriageReturn)
            }
        }

        /// Creates a collection holding copies of `elements`, packed.
        public init(arrayLiteral elements: DiffTextLine...) {
            self.init(elements)
        }

        /// Always 0.
        public var startIndex: Int { 0 }

        /// The line at `position`, which must be in `indices`.
        public subscript(position: Int) -> DiffTextLine {
            precondition(indices.contains(position), "DiffFile.TextLines index out of range")
            let record = records[offset + position]
            return DiffTextLine(content: bytes[record.range], endsWithCarriageReturn: record.endsWithCarriageReturn)
        }

        /// Appends a copy of `content`. Only for a collection that owns its
        /// storage, such as a diff's preamble: a view into a file's would
        /// copy the file's whole arena.
        mutating func append(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) {
            precondition(offset + endIndex == records.count, "only the tail of its records can grow")
            let start = bytes.count
            Storage.copy(content, into: &bytes)
            records.append(TextRecord(
                range: start..<bytes.count, endsWithCarriageReturn: endsWithCarriageReturn
            ))
            endIndex += 1
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
