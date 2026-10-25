/// Assembles one file's `FileHeader` from its header block, a line at a time.
///
/// Start it with the file's `diff ` line (or a plain diff's `--- ` line),
/// feed it the following lines until `consume(_:)` returns false, then
/// take `header(isBinary:)`. Values that don't parse — an overflowing
/// mode, a similarity over 100, a non-hex object ID — are ignored, as
/// `git apply` ignores or rejects them, so damage degrades the header
/// instead of trapping. Repeated lines replace earlier ones, so memory
/// stays bounded by the line cap whatever the input.
struct FileHeaderParser: Sendable {
    /// A `---` or `+++` payload, with its trailer cut and quoting undone.
    private enum Side: Sendable, Equatable {
        case devNull
        case path([UInt8])
    }

    private typealias Handler = @Sendable (inout FileHeaderParser, ArraySlice<UInt8>) -> Void

    let format: FileHeader.Format
    /// The `diff --git` line's name, when both of its names agree.
    private let gitLinePath: DiffPath?
    private var oldSide: Side?
    private var newSide: Side?
    private var renameFrom: DiffPath?
    private var renameTo: DiffPath?
    private var copyFrom: DiffPath?
    private var copyTo: DiffPath?
    private var isRename = false
    private var isCopy = false
    private var isCreation = false
    private var isDeletion = false
    private var oldMode: FileMode?
    private var newMode: FileMode?
    /// The mode an `index` line names for both sides of a modification.
    private var indexMode: FileMode?
    private var similarity: Int?
    private var dissimilarity: Int?
    private var oldObjectID: ObjectID?
    private var newObjectID: ObjectID?

    /// Starts a file at its `diff ` line; nil for a combined diff
    /// (`diff --cc`, `diff --combined`), which 0.2 skips (D9).
    init?(diffLine line: ArraySlice<UInt8>) {
        if let names = line.dropping(prefix: Self.gitPrefix) {
            format = .git
            gitLinePath = Self.gitLinePath(names)
        } else if line.dropping(prefix: Self.combinedPrefix) != nil || line.dropping(prefix: Self.densePrefix) != nil {
            return nil
        } else {
            // `diff -ruN old/x new/x` and the like: paths come from ---/+++.
            format = .unified
            gitLinePath = nil
        }
    }

    /// Starts a plain diff's file at its `--- ` line.
    init(plainOldSideLine line: ArraySlice<UInt8>) {
        format = .unified
        gitLinePath = nil
        consume(line)
    }

    /// Takes the next line of the header block. Returns false, changing
    /// nothing, when the line isn't a header line: the block has ended.
    @discardableResult
    mutating func consume(_ line: ArraySlice<UInt8>) -> Bool {
        let handlers = format == .git ? Self.gitHandlers : Self.unifiedHandlers
        guard let (handler, value) = handlers.lazy
            .compactMap({ prefix, handler in line.dropping(prefix: prefix).map { (handler, $0) } })
            .first
        else { return false }
        handler(&self, value)
        return true
    }

    /// The header as assembled so far.
    func header(isBinary: Bool) -> FileHeader {
        let isAdded = isCreation || oldSide == .devNull
        let isDeleted = !isAdded && (isDeletion || newSide == .devNull)
        // git's precedence when markers contradict: creation, deletion,
        // rename, copy.
        let change: Change = if isAdded {
            .added
        } else if isDeleted {
            .deleted
        } else if isRename {
            .renamed(similarity: similarity)
        } else if isCopy {
            .copied(similarity: similarity)
        } else {
            .modified
        }
        let sides = Self.sidePaths(old: oldSide, new: newSide)
        let oldPath = (isRename ? renameFrom : nil) ?? (isCopy ? copyFrom : nil) ?? sides.old ?? gitLinePath
        let newPath = (isRename ? renameTo : nil) ?? (isCopy ? copyTo : nil) ?? sides.new ?? gitLinePath
        return FileHeader(
            format: format,
            change: change,
            oldPath: isAdded ? nil : oldPath,
            newPath: isDeleted ? nil : newPath,
            oldMode: oldMode ?? (isAdded ? nil : indexMode),
            newMode: newMode ?? (isDeleted ? nil : indexMode),
            oldObjectID: oldObjectID,
            newObjectID: newObjectID,
            dissimilarity: dissimilarity,
            isBinary: isBinary
        )
    }

    // MARK: Header lines

    private static let gitPrefix = Array("diff --git ".utf8)
    private static let combinedPrefix = Array("diff --combined ".utf8)
    private static let densePrefix = Array("diff --cc ".utf8)

    private static let sideHandlers: [([UInt8], Handler)] = [
        (Array("--- ".utf8), { $0.oldSide = side(of: $1) }),
        (Array("+++ ".utf8), { $0.newSide = side(of: $1) }),
    ]

    /// git's extended headers (`apply.c`'s table), plus `---`/`+++`.
    private static let gitHandlers: [([UInt8], Handler)] = sideHandlers + [
        (Array("old mode ".utf8), { $0.oldMode = FileMode(octal: $1) }),
        (Array("new mode ".utf8), { $0.newMode = FileMode(octal: $1) }),
        (Array("deleted file mode ".utf8), { $0.isDeletion = true; $0.oldMode = FileMode(octal: $1) }),
        (Array("new file mode ".utf8), { $0.isCreation = true; $0.newMode = FileMode(octal: $1) }),
        (Array("copy from ".utf8), { $0.isCopy = true; $0.copyFrom = path(of: $1) }),
        (Array("copy to ".utf8), { $0.isCopy = true; $0.copyTo = path(of: $1) }),
        // "rename old"/"rename new" are git's original spellings.
        (Array("rename from ".utf8), { $0.isRename = true; $0.renameFrom = path(of: $1) }),
        (Array("rename old ".utf8), { $0.isRename = true; $0.renameFrom = path(of: $1) }),
        (Array("rename to ".utf8), { $0.isRename = true; $0.renameTo = path(of: $1) }),
        (Array("rename new ".utf8), { $0.isRename = true; $0.renameTo = path(of: $1) }),
        (Array("similarity index ".utf8), { $0.similarity = percentage(of: $1) }),
        (Array("dissimilarity index ".utf8), { $0.dissimilarity = percentage(of: $1) }),
        (Array("index ".utf8), { $0.parseIndex($1) }),
    ]

    private static let unifiedHandlers = sideHandlers

    /// `index <old>..<new>[ <mode>]`; each part that doesn't parse is
    /// dropped on its own. A combined diff's `a,b..c` never gets here.
    private mutating func parseIndex(_ value: ArraySlice<UInt8>) {
        // As in git, the first dot must start the "..".
        guard let dot = value.firstIndex(of: UInt8(ascii: ".")),
              let rest = value[dot...].dropping(prefix: Self.dotDot)
        else { return }
        let newEnd = rest.firstIndex(of: UInt8(ascii: " ")) ?? rest.endIndex
        oldObjectID = ObjectID(hex: value[..<dot])
        newObjectID = ObjectID(hex: rest[..<newEnd])
        indexMode = newEnd < rest.endIndex ? FileMode(octal: rest[rest.index(after: newEnd)...]) : nil
    }

    private static let dotDot = Array("..".utf8)

    /// A `similarity`/`dissimilarity index` value: leading digits, at most
    /// 100. Like `git apply`, a larger value is ignored rather than clamped.
    private static func percentage(of value: ArraySlice<UInt8>) -> Int? {
        let digits = value.prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        guard !digits.isEmpty else { return nil }
        // Saturates past 100 instead of overflowing on an absurd digit run.
        let number = digits.reduce(0) { partial, digit in
            partial > 100 ? partial : partial * 10 + Int(digit - UInt8(ascii: "0"))
        }
        return number <= 100 ? number : nil
    }

    /// A `rename`/`copy` path: the rest of the line, unquoted, never
    /// prefixed.
    private static func path(of value: ArraySlice<UInt8>) -> DiffPath? {
        let bytes = PathQuoting.unquoted(value)
        return bytes.isEmpty ? nil : DiffPath(bytes)
    }

    /// A `---`/`+++` payload: up to a tab-appended trailer (a timestamp,
    /// or git's marker after a path with spaces), then unquoted.
    private static func side(of value: ArraySlice<UInt8>) -> Side {
        let name = value.prefix { $0 != UInt8(ascii: "\t") }
        let bytes = PathQuoting.unquoted(name)
        return bytes == devNull ? .devNull : .path(bytes)
    }

    private static let devNull = Array("/dev/null".utf8)

    // MARK: Prefixes and paths

    /// Letters git uses as diff prefixes: a/b by default (swapped by -R),
    /// c/i/o/w under diff.mnemonicPrefix. Same set as `DiffParser`'s.
    private static let prefixLetters = Array("abciow".utf8)

    private static func prefixLetter(of path: [UInt8]) -> UInt8? {
        guard path.count >= 2, prefixLetters.contains(path[0]), path[1] == UInt8(ascii: "/") else { return nil }
        return path[0]
    }

    /// Strips git's `a/`-style prefixes from a pair of names the way
    /// `DiffParser` treats `+++`: a side with a prefix letter loses it
    /// unless the other side contradicts it. Real git prefix pairs use two
    /// different letters, so the same letter on both sides, or a letter
    /// against a bare path, is a genuine directory and is kept.
    private static func strippingPrefixes(_ old: [UInt8]?, _ new: [UInt8]?) -> (old: [UInt8]?, new: [UInt8]?) {
        func stripped(_ path: [UInt8]?, pairedWith other: [UInt8]?) -> [UInt8]? {
            guard let path, let letter = prefixLetter(of: path) else { return path }
            guard let other else { return Array(path.dropFirst(2)) }
            guard let otherLetter = prefixLetter(of: other), otherLetter != letter else { return path }
            return Array(path.dropFirst(2))
        }
        return (stripped(old, pairedWith: new), stripped(new, pairedWith: old))
    }

    private static func sidePaths(old: Side?, new: Side?) -> (old: DiffPath?, new: DiffPath?) {
        func bytes(_ side: Side?) -> [UInt8]? {
            guard case .path(let bytes) = side else { return nil }
            return bytes
        }
        let pair = strippingPrefixes(bytes(old), bytes(new))
        func path(_ bytes: [UInt8]?) -> DiffPath? {
            guard let bytes, !bytes.isEmpty else { return nil }
            return DiffPath(bytes)
        }
        return (path(pair.old), path(pair.new))
    }

    /// The name on a `diff --git` line when both names agree, split the
    /// way `git apply` splits it; nil for a rename or anything ambiguous.
    ///
    /// Equal names with equal-length prefixes put the separator exactly in
    /// the middle of an unquoted pair, so the split costs one comparison,
    /// even on a hostile megabyte of spaces.
    static func gitLinePath(_ names: ArraySlice<UInt8>) -> DiffPath? {
        let quote = UInt8(ascii: "\"")
        let first: [UInt8]
        let second: [UInt8]
        if let end = PathQuoting.endOfQuotedPrefix(names) {
            first = PathQuoting.unquoted(names[..<end])
            let rest = names[end...].drop { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
            guard !rest.isEmpty else { return nil }
            if rest.first == quote {
                guard PathQuoting.endOfQuotedPrefix(rest) == rest.endIndex else { return nil }
            }
            second = PathQuoting.unquoted(rest)
        } else if let secondStart = names.firstIndex(of: quote) {
            // An unquoted name can't contain a quote, so this one opens the second.
            guard secondStart > names.startIndex,
                  isSeparator(names[names.index(before: secondStart)]),
                  PathQuoting.endOfQuotedPrefix(names[secondStart...]) == names.endIndex
            else { return nil }
            first = Array(names[..<names.index(before: secondStart)])
            second = PathQuoting.unquoted(names[secondStart...])
        } else {
            guard names.count % 2 == 1 else { return nil }
            let middle = names.index(names.startIndex, offsetBy: names.count / 2)
            guard isSeparator(names[middle]) else { return nil }
            first = Array(names[..<middle])
            second = Array(names[names.index(after: middle)...])
        }
        let pair = strippingPrefixes(first, second)
        guard let old = pair.old, !old.isEmpty, old == pair.new else { return nil }
        return DiffPath(old)
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }
}

extension ArraySlice<UInt8> {
    /// The rest of the slice after `prefix`, or nil if it doesn't start with it.
    func dropping(prefix: [UInt8]) -> ArraySlice<UInt8>? {
        starts(with: prefix) ? dropFirst(prefix.count) : nil
    }
}
