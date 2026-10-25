/// Splits a streamed diff into files, recording each one's header and how
/// many lines its hunks add and delete.
///
/// Scaffolding for plan step 2.3: it runs `FileHeaderParser` over whole
/// diffs so headers can be checked against `git apply`, and step 2.4's
/// event parser takes its place. The hunk bookkeeping mirrors
/// `DiffParser`'s, so a damaged hunk recovers at the same lines.
///
/// A header block runs from a file's `diff ` line (or a plain diff's
/// `---`/`+++` pair) to its first hunk, binary marker, or a line that isn't
/// a header line. Extended headers are recognized only there, so hunk
/// content can never be read as one. Combined diffs are skipped (D9).
struct FileHeaderScanner: ByteLineConsumer, Sendable {
    /// One file of the diff.
    struct File: Sendable, Equatable {
        var header: FileHeader
        var addedLines = 0
        var deletedLines = 0
    }

    var partialLine: [UInt8] = []
    private var files: [File] = []
    /// The open header block, if any.
    private var header: FileHeaderParser?
    /// The file whose header is complete and whose hunks are being counted.
    private var current: File?
    /// A plain diff's `--- ` line outside a header, kept for one line to
    /// see whether a `+++ ` pairs with it.
    private var pendingOldSide: [UInt8]?
    /// Set from a combined diff's `diff --cc` line to the next `diff ` line.
    private var isSkippingCombinedFile = false
    private var remainingOld = 0
    private var remainingNew = 0

    init() {}

    mutating func consume(_ chunk: ArraySlice<UInt8>) {
        consumeChunk(chunk)
    }

    mutating func finalize() -> [File] {
        flushPartialLine()
        endFile()
        return files
    }

    // MARK: Lines

    private static let diffPrefix = Array("diff ".utf8)
    private static let oldSidePrefix = Array("--- ".utf8)
    private static let newSidePrefix = Array("+++ ".utf8)
    private static let binaryFilesPrefix = Array("Binary files ".utf8)
    /// GNU diff's wording when it doesn't say "binary"; `git apply` takes it too.
    private static let filesPrefix = Array("Files ".utf8)
    private static let binaryPatchMarker = Array("GIT binary patch".utf8)

    mutating func processLine(_ line: ArraySlice<UInt8>) {
        if remainingOld > 0 || remainingNew > 0 {
            return processHunkLine(line)
        }
        let oldSide = pendingOldSide
        pendingOldSide = nil
        if line.starts(with: Self.diffPrefix) {
            endFile()
            header = FileHeaderParser(diffLine: line)
            isSkippingCombinedFile = header == nil
            return
        }
        guard !isSkippingCombinedFile else { return }
        if var open = header {
            if open.consume(line) {
                header = open
                return
            }
            let isBinary = Self.isBinaryMarker(line)
            header = nil
            current = File(header: open.header(isBinary: isBinary))
            if isBinary { return }
        }
        if let oldSide, line.starts(with: Self.newSidePrefix) {
            endFile()
            var open = FileHeaderParser(plainOldSideLine: oldSide[...])
            open.consume(line)
            header = open
        } else if line.starts(with: Self.oldSidePrefix) {
            pendingOldSide = Array(line)
        } else if let hunk = DiffParser.parseHunkHeader(line) {
            remainingOld = hunk.oldCount
            remainingNew = hunk.newCount
        }
    }

    private static func isBinaryMarker(_ line: ArraySlice<UInt8>) -> Bool {
        line.elementsEqual(binaryPatchMarker) || line.starts(with: binaryFilesPrefix) || line.starts(with: filesPrefix)
    }

    /// Counts one hunk line against the declared budgets, as `DiffParser`
    /// does; a line the budgets can't absorb ends the hunk and is read again
    /// outside it.
    private mutating func processHunkLine(_ line: ArraySlice<UInt8>) {
        if line.starts(with: Self.diffPrefix) {
            return reprocessOutsideHunk(line)
        }
        switch line.first {
        case UInt8(ascii: "+"):
            guard remainingNew > 0 else { return reprocessOutsideHunk(line) }
            current?.addedLines += 1
            remainingNew -= 1
        case UInt8(ascii: "-"):
            guard remainingOld > 0 else { return reprocessOutsideHunk(line) }
            current?.deletedLines += 1
            remainingOld -= 1
        case UInt8(ascii: "\\"):
            break
        default:
            guard remainingOld > 0, remainingNew > 0 else { return reprocessOutsideHunk(line) }
            remainingOld -= 1
            remainingNew -= 1
        }
    }

    private mutating func reprocessOutsideHunk(_ line: ArraySlice<UInt8>) {
        remainingOld = 0
        remainingNew = 0
        processLine(line)
    }

    private mutating func endFile() {
        if let open = header {
            current = File(header: open.header(isBinary: false))
        }
        header = nil
        if let current {
            files.append(current)
        }
        current = nil
        isSkippingCombinedFile = false
    }
}
