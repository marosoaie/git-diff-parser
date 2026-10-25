/// Byte patterns and bounds of diff syntax, shared by the parser's aspects
/// (a generic type can't hold static stored properties).
enum DiffSyntax {
    static let diffPrefix = Array("diff ".utf8)
    static let oldSidePrefix = Array("--- ".utf8)
    static let newSidePrefix = Array("+++ ".utf8)
    static let hunkPrefix = Array("@@".utf8)
    static let binaryFilesPrefix = Array("Binary files ".utf8)
    /// GNU diff's wording when it doesn't say "binary"; `git apply` takes it too.
    static let filesPrefix = Array("Files ".utf8)
    static let binaryPatchMarker = Array("GIT binary patch".utf8)
    static let literalPrefix = Array("literal ".utf8)
    static let deltaPrefix = Array("delta ".utf8)
    /// The part of `\ No newline at end of file` that `git apply` checks;
    /// the rest depends on the locale.
    static let noNewlinePrefix = Array("\\ ".utf8)

    /// A header block past either bound abandons its file. Fixed rather
    /// than tied to the line cap, which a caller may raise to 64 MiB.
    static let maximumHeaderLines = 64
    static let maximumHeaderBytes = 1 << 20

    /// Combined diffs against more parents abandon the file; git's own
    /// octopus merges stay far below it.
    static let maximumParents = 64

    /// A line that ends a header block and belongs to it: the file is binary.
    static func isBinaryMarker(_ line: ArraySlice<UInt8>) -> Bool {
        line.elementsEqual(binaryPatchMarker) || line.starts(with: binaryFilesPrefix) || line.starts(with: filesPrefix)
    }

    /// The first byte of a base85 line encodes its length as `A`–`Z` (1–26)
    /// or `a`–`z` (27–52).
    static func isBase85LengthByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }
}

/// An open header block.
struct HeaderBlock: Sendable {
    var parser: FileHeaderParser
    var lineCount = 0
    /// Over its bounds: its lines are still recognized, so the block ends
    /// where it would have, but no longer buffered.
    var isAbandoned = false
}

/// What the parser does with the current file's lines.
enum FileState: Sendable {
    /// No file yet, or the last one ended.
    case none
    /// `beginFile` was sent; hunks produce events.
    case open(FileHeader)
    /// A combined diff's file: `beginFile` was sent, and hunks are counted
    /// against each parent's budget without events.
    case combined(FileHeader, parents: Int)
    /// A damaged file: hunks are counted, so their content can't start a
    /// file, and every line is dropped until the next file starts.
    case abandoned
    /// A damaged combined file (too many parents, or a header over its
    /// bounds), whose hunks aren't counted: every line up to the next
    /// `diff ` line is dropped.
    case skippingToNextDiffLine

    var header: FileHeader? {
        switch self {
        case .open(let header), .combined(let header, _): header
        case .none, .abandoned, .skippingToNextDiffLine: nil
        }
    }

    /// Whether `beginFile` was sent, so `endFile` is owed.
    var hasBegun: Bool { header != nil }

    var isCombined: Bool {
        if case .combined = self { true } else { false }
    }

    var dropsLines: Bool {
        switch self {
        case .abandoned, .skippingToNextDiffLine: true
        case .none, .open, .combined: false
        }
    }
}

/// The hunk being read, and what's left of its declared ranges.
struct HunkState: Sendable {
    var remainingOld = 0
    var remainingNew = 0
    var oldLine = 0
    var newLine = 0
    /// Whether line events go out; false for a hunk with no file to
    /// deliver them to, and for a combined file's hunks.
    var emitsEvents = false
    /// Whether damage inside the hunk is reported; false when the hunk's
    /// own report (no file) or the file's (abandoned) already covers it.
    var reportsDamage = false
    var isCombined = false
    /// A combined hunk's remaining lines per parent; `remainingOld` holds
    /// their sum, so `isOpen` covers both kinds.
    var parentRemaining: [Int] = []
    /// The input line number of the last content line, so a
    /// `\ No newline at end of file` can check that it follows one.
    var lastContentLine = -1

    var isOpen: Bool { remainingOld > 0 || remainingNew > 0 }

    mutating func close() {
        remainingOld = 0
        remainingNew = 0
        parentRemaining.removeAll(keepingCapacity: true)
    }
}

/// Where a `GIT binary patch` block is: a forward part, then optionally a
/// reverse one, each `literal`/`delta` + base85 lines + a blank line.
enum BinaryPatchPosition: Sendable, Equatable {
    case expectingFirstPart
    case inPart
    case betweenParts
}
