extension DiffFile {
    /// A file's hunks, in order, read from its packed storage.
    ///
    /// Indices run from 0 to `count`. Elements are built on access and
    /// share the file's storage.
    public struct Hunks: RandomAccessCollection, ExpressibleByArrayLiteral, Sendable, Equatable {
        private let storage: Storage

        init(of storage: Storage) {
            self.storage = storage
        }

        /// Creates a collection holding copies of `hunks`, packed.
        public init(_ hunks: some Sequence<DiffHunk>) {
            var storage = Storage()
            hunks.forEach { storage.append($0) }
            self.init(of: storage)
        }

        /// Creates a collection holding copies of `elements`, packed.
        public init(arrayLiteral elements: DiffHunk...) {
            self.init(elements)
        }

        /// Always 0.
        public var startIndex: Int { 0 }

        /// The number of hunks.
        public var endIndex: Int { storage.hunks.count }

        /// The hunk at `position`, which must be in `indices`.
        public subscript(position: Int) -> DiffHunk {
            let record = storage.hunks[position]
            let next = position + 1 < storage.hunks.count ? storage.hunks[position + 1] : nil
            return DiffHunk(
                header: record.header,
                heading: storage.textBytes[record.heading],
                lines: Lines(of: storage, range: record.firstLine..<(next?.firstLine ?? storage.lines.count)),
                trailingLines: TextLines(
                    bytes: storage.textBytes,
                    records: storage.unrecognizedLines,
                    range: record.firstTrailingLine..<(next?.firstTrailingLine ?? storage.unrecognizedLines.count)
                )
            )
        }

        /// Whether both hold equal hunks in the same order, however they are
        /// stored.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.elementsEqual(rhs)
        }
    }
}
