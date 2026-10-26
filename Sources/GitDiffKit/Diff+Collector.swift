extension Diff {
    /// Collects the full model, ``Diff``, from parser events.
    ///
    /// ```swift
    /// var parser = DiffEventParser<Diff.Collector>()
    /// while let chunk = readSomeBytes() { parser.consume(chunk) }
    /// let diff = parser.finalize().diff
    /// ```
    ///
    /// That initializer raises the line cap to 64 MiB. Created with
    /// ``DiffEventParser/init(consumer:options:)`` instead, pass
    /// `options: .fullModel`, or lines over the default 1 MiB are cut.
    ///
    /// Memory grows with the diff's content; see ``Diff``.
    public struct Collector: DiffEventConsumer, Sendable {
        /// The model collected so far; complete once the parser is
        /// finalized.
        public private(set) var diff = Diff()
        /// The open file, appended to `diff` when it ends, so a line
        /// appends to its storage directly rather than through an array
        /// element.
        private var file: DiffFile?

        /// Creates a collector with nothing collected.
        public init() {}

        /// Opens the file, copying its raw header.
        public mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>) {
            endFile()
            file = DiffFile(header: header, rawHeader: rawHeader)
        }

        /// Opens a hunk in the open file.
        public mutating func beginHunk(_ header: HunkHeader, heading: Span<UInt8>) {
            file?.storage.appendHunk(header, heading: heading)
        }

        /// Copies the line into the open hunk.
        public mutating func line(_ line: LineInfo, content: Span<UInt8>) {
            guard file?.storage.hunks.isEmpty == false else { return }
            file?.storage.appendLine(line, content: content)
        }

        /// Flags the open file's last line.
        public mutating func noNewlineAtEndOfFile(endsWithCarriageReturn: Bool) {
            file?.storage.markNoNewlineAtEnd(markerEndsWithCarriageReturn: endsWithCarriageReturn)
        }

        /// Copies the line into the open file's binary patch.
        public mutating func binaryPatchLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) {
            file?.storage.appendBinaryPatchLine(content, endsWithCarriageReturn: endsWithCarriageReturn)
        }

        /// Records the open file.
        public mutating func endFile() {
            if let file {
                diff.files.append(file)
            }
            file = nil
        }

        /// Keeps the line where it appeared: in the open file, else in the
        /// preamble before the first file, else after the last file, so
        /// input order is kept.
        public mutating func unrecognizedLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) {
            if file != nil {
                file?.storage.appendUnrecognizedLine(content, endsWithCarriageReturn: endsWithCarriageReturn)
            } else if diff.files.isEmpty {
                diff.preamble.append(content, endsWithCarriageReturn: endsWithCarriageReturn)
            } else {
                diff.files[diff.files.count - 1].storage.appendUnrecognizedLine(
                    content, endsWithCarriageReturn: endsWithCarriageReturn
                )
            }
        }

        /// Keeps the report.
        public mutating func damage(_ report: DamageReport) {
            diff.damage.append(report)
        }

        /// Flags the diff's last line.
        public mutating func noNewlineAtEndOfInput() {
            diff.hasNoNewlineAtEnd = true
        }
    }
}
