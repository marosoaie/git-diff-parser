/// One file of a diff in the full model: its header, the header's raw
/// bytes, and its hunks with every line's content.
///
/// The file's bytes are packed into per-file arenas, with lines stored as
/// offsets (see docs/diff-model.md, D8), so its collections — `hunks`,
/// `lines`, `binaryPatchLines`, `leadingLines` — build their elements on
/// access, as slices of that storage. Holding any element keeps the whole
/// file's storage alive.
///
/// In input order, a file is its raw header, then its binary patch lines,
/// its leading lines, and its hunks, each followed by its trailing lines.
public struct DiffFile: Sendable, Equatable, CustomReflectable {
    /// What the diff says about the file: status, paths, modes, and
    /// whether it is binary.
    public var header: FileHeader
    var storage: Storage

    /// Creates a file from its parts, copying their bytes into the file's
    /// own storage.
    public init(
        header: FileHeader,
        rawHeader: ArraySlice<UInt8> = [],
        binaryPatchLines: TextLines = [],
        leadingLines: TextLines = [],
        hunks: Hunks = []
    ) {
        self.init(header: header, rawHeader: rawHeader.span)
        binaryPatchLines.forEach { line in
            let content = line.content
            storage.appendBinaryPatchLine(content.span, endsWithCarriageReturn: line.endsWithCarriageReturn)
        }
        leadingLines.forEach { line in
            let content = line.content
            storage.appendUnrecognizedLine(content.span, endsWithCarriageReturn: line.endsWithCarriageReturn)
        }
        hunks.forEach { storage.append($0) }
    }

    init(header: FileHeader, rawHeader: Span<UInt8>) {
        self.header = header
        storage = Storage(rawHeader: rawHeader)
    }

    /// The file's header block verbatim, from its `diff` line (or `---`
    /// line, in plain `diff -u` output) up to its first hunk, each line
    /// with its `\r` and `\n`. It includes a `Binary files … differ` or
    /// `GIT binary patch` line, which ends the block.
    public var rawHeader: ArraySlice<UInt8> {
        storage.textBytes[..<storage.rawHeaderCount]
    }

    /// The lines of the file's `GIT binary patch` block after its marker
    /// line, undecoded: `literal`/`delta` lines, base85 data, and the blank
    /// line ending each part. Empty for other files.
    public var binaryPatchLines: TextLines {
        TextLines(bytes: storage.textBytes, records: storage.binaryPatchLines, range: storage.binaryPatchLines.indices)
    }

    /// Unrecognized lines after the header (and binary patch), before the
    /// first hunk; all of the file's when it has no hunks.
    public var leadingLines: TextLines {
        let end = storage.hunks.first?.firstTrailingLine ?? storage.unrecognizedLines.count
        return TextLines(bytes: storage.textBytes, records: storage.unrecognizedLines, range: 0..<end)
    }

    /// The file's hunks, in order. Empty for a binary file, a pure rename
    /// or mode change, and a combined diff, whose hunks are skipped.
    public var hunks: Hunks {
        Hunks(of: storage)
    }

    /// Every hunk's lines, in order.
    public var lines: Lines {
        Lines(of: storage, range: storage.lines.indices)
    }

    /// Whether both files have the same header, raw header, and contents,
    /// however they are stored.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.header == rhs.header
            && lhs.rawHeader == rhs.rawHeader
            && lhs.binaryPatchLines == rhs.binaryPatchLines
            && lhs.leadingLines == rhs.leadingLines
            && lhs.hunks == rhs.hunks
    }

    /// The file's parts, so printing shows them rather than the packed
    /// storage.
    public var customMirror: Mirror {
        Mirror(self, children: [
            "header": header,
            "rawHeader": rawHeader,
            "binaryPatchLines": binaryPatchLines,
            "leadingLines": leadingLines,
            "hunks": hunks,
        ], displayStyle: .struct)
    }
}
