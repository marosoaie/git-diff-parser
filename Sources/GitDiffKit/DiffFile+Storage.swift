extension DiffFile {
    /// A file's content, packed (D8): bytes in two arenas, records as
    /// offsets into them, so a file costs a handful of allocations however
    /// many lines it has, rather than one per line.
    ///
    /// Hunk line content has its own arena, back to back, so a line record
    /// stores only where its content ends (it starts where the previous
    /// one's ends) and stays 32 bytes. Everything else — the raw header,
    /// headings, binary patch lines, unrecognized lines — goes into the
    /// other arena in input order. Offsets are `Int`, so no file size
    /// limit needs checking.
    struct Storage: Sendable {
        var lineBytes: [UInt8] = []
        var textBytes: [UInt8] = []
        /// The raw header is `textBytes`' first bytes.
        var rawHeaderCount = 0
        var lines: [LineRecord] = []
        var hunks: [HunkRecord] = []
        var binaryPatchLines: [TextRecord] = []
        /// The file's leading lines, then each hunk's trailing lines.
        var unrecognizedLines: [TextRecord] = []

        init() {}

        init(rawHeader: Span<UInt8>) {
            Self.copy(rawHeader, into: &textBytes)
            rawHeaderCount = textBytes.count
        }

        mutating func appendHunk(_ header: HunkHeader, heading: Span<UInt8>) {
            let start = textBytes.count
            Self.copy(heading, into: &textBytes)
            hunks.append(HunkRecord(
                header: header,
                heading: start..<textBytes.count,
                firstLine: lines.count,
                firstTrailingLine: unrecognizedLines.count
            ))
        }

        mutating func appendLine(_ info: LineInfo, content: Span<UInt8>) {
            Self.copy(content, into: &lineBytes)
            lines.append(LineRecord(info, contentEnd: lineBytes.count))
        }

        /// Flags the last line, if any.
        mutating func markNoNewlineAtEnd() {
            guard !lines.isEmpty else { return }
            lines[lines.count - 1].flags.insert(.hasNoNewlineAtEnd)
        }

        mutating func appendBinaryPatchLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) {
            binaryPatchLines.append(appendText(content, endsWithCarriageReturn: endsWithCarriageReturn))
        }

        /// Appends to the last hunk's trailing lines, or to the leading
        /// lines before the first hunk.
        mutating func appendUnrecognizedLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) {
            unrecognizedLines.append(appendText(content, endsWithCarriageReturn: endsWithCarriageReturn))
        }

        /// Appends a whole hunk built from values, as `appendHunk` and the
        /// line appends would have from events.
        mutating func append(_ hunk: DiffHunk) {
            let heading = hunk.heading
            appendHunk(hunk.header, heading: heading.span)
            hunk.lines.forEach { append($0) }
            hunk.trailingLines.forEach { line in
                let content = line.content
                appendUnrecognizedLine(content.span, endsWithCarriageReturn: line.endsWithCarriageReturn)
            }
        }

        mutating func append(_ line: DiffLine) {
            let content = line.content
            appendLine(line.info, content: content.span)
            if line.hasNoNewlineAtEnd {
                markNoNewlineAtEnd()
            }
        }

        private mutating func appendText(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) -> TextRecord {
            let start = textBytes.count
            Self.copy(content, into: &textBytes)
            return TextRecord(range: start..<textBytes.count, endsWithCarriageReturn: endsWithCarriageReturn)
        }

        /// A byte at a time: copying a span in bulk takes
        /// `withUnsafeBufferPointer`, whose `unsafe` marking Swift 6.2
        /// requires and 6.4 warns about, and this is within 15 ms of it on
        /// the kernel diff's 72 MB.
        static func copy(_ span: Span<UInt8>, into bytes: inout [UInt8]) {
            span.indices.forEach { bytes.append(span[$0]) }
        }
    }
}
