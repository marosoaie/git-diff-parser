import Foundation
import StreamParsing

/// Streaming parser for unified diffs as produced by `git diff` / `git show`.
///
/// Feed it the diff in arbitrary byte chunks (any size, split anywhere) and
/// call `finalize()` once at the end. Memory use is bounded by the size of the
/// *result* (one range per contiguous run of added lines), not by the size
/// of the input, so multi-hundred-megabyte diffs parse in constant working
/// memory.
///
///     var parser = DiffParser()
///     while let chunk = readSomeBytes() { parser.consume(chunk) }
///     let changes = parser.finalize()
public struct DiffParser: ByteLineConsumer, Sendable {
    package var partialLine: [UInt8] = []

    private var changes = ChangedLines()

    // Path of the file currently being processed (new side), or nil when
    // the current file is deleted (`+++ /dev/null`) or binary.
    private var currentPath: String?
    // Line number in the new file for the next hunk line we encounter.
    private var newLine = 0
    // Hunk lines still expected on each side; both zero means we are
    // between hunks and +/- lines are file headers or junk, not content.
    private var remainingOld = 0
    private var remainingNew = 0

    public init() {}

    // MARK: Input

    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        consumeChunk(chunk)
    }

    public mutating func consume(_ chunk: [UInt8]) {
        consumeChunk(chunk[...])
    }

    public mutating func consume(_ chunk: Data) {
        consumeChunk([UInt8](chunk)[...])
    }

    public mutating func consume(_ text: String) {
        consumeChunk(Array(text.utf8)[...])
    }

    /// Flushes any unterminated final line and returns the result.
    public mutating func finalize() -> ChangedLines {
        flushPartialLine()
        return changes
    }

    // MARK: Per-line parsing

    private static let fileHeaderPrefix = Array("+++ ".utf8)
    private static let oldFileHeaderPrefix = Array("--- ".utf8)
    private static let diffLinePrefix = Array("diff ".utf8)
    private static let binaryPrefix = Array("Binary files ".utf8)

    // Prefix class of the most recent "--- " header; disambiguates whether a
    // single-letter prefix on the "+++ " side is git's or a real directory.
    private var oldSideHeader: HeaderPathPrefix = .unknown

    package mutating func processLine(_ line: ArraySlice<UInt8>) {
        if remainingOld > 0 || remainingNew > 0 {
            processHunkContentLine(line)
            return
        }

        if line.starts(with: Self.fileHeaderPrefix) {
            currentPath = Self.parseFileHeaderPath(
                String(decoding: line.dropFirst(Self.fileHeaderPrefix.count), as: UTF8.self),
                pairedWith: oldSideHeader
            )
            oldSideHeader = .unknown
        } else if line.starts(with: Self.oldFileHeaderPrefix) {
            oldSideHeader = Self.headerPrefixClass(
                of: String(decoding: line.dropFirst(Self.oldFileHeaderPrefix.count), as: UTF8.self)
            )
        } else if line.starts(with: Self.diffLinePrefix) || line.starts(with: Self.binaryPrefix) {
            currentPath = nil
            oldSideHeader = .unknown
        } else if let hunk = Self.parseHunkHeader(line) {
            newLine = hunk.newStart
            remainingOld = hunk.oldCount
            remainingNew = hunk.newCount
        }
    }

    private mutating func processHunkContentLine(_ line: ArraySlice<UInt8>) {
        // A bare "diff " line can only appear mid-hunk when the hunk was
        // truncated: well-formed content lines always carry a +/-/space
        // marker. Recover here so a malformed file can't record phantom
        // lines or swallow the next file's headers.
        if line.starts(with: Self.diffLinePrefix) {
            remainingOld = 0
            remainingNew = 0
            currentPath = nil
            return
        }
        // Each marker must have budget on its own side of the hunk, or a
        // malformed hunk could invent lines the declared counts never
        // promised (e.g. a "+" in a deletion-only hunk).
        switch line.first {
        case UInt8(ascii: "+"):
            guard remainingNew > 0 else { return reprocessOutsideHunk(line) }
            if let path = currentPath {
                changes.add(line: newLine, to: path)
            }
            newLine += 1
            remainingNew -= 1
        case UInt8(ascii: "-"):
            guard remainingOld > 0 else { return reprocessOutsideHunk(line) }
            remainingOld -= 1
        case UInt8(ascii: "\\"):
            // "\ No newline at end of file" — annotation, not content.
            break
        default:
            // Context line. Diffs that passed through trailing-whitespace
            // stripping may turn " " into "", so treat any other line
            // inside a hunk as context.
            guard remainingOld > 0, remainingNew > 0 else { return reprocessOutsideHunk(line) }
            newLine += 1
            remainingOld -= 1
            remainingNew -= 1
        }
    }

    /// A line inconsistent with the declared hunk counts means the hunk is
    /// malformed: abandon it and reinterpret the line as header material, so
    /// a corrupted count can't swallow the next file header.
    private mutating func reprocessOutsideHunk(_ line: ArraySlice<UInt8>) {
        remainingOld = 0
        remainingNew = 0
        processLine(line)
    }

    // MARK: Header parsing helpers

    /// Prefix class of a `--- ` or `+++ ` header payload.
    enum HeaderPathPrefix: Equatable {
        /// No paired header seen (raw fragments, direct API use).
        case unknown
        /// The old side was `/dev/null` (file creation).
        case devNull
        /// A path with no single-letter prefix component.
        case bare
        /// A path starting `<letter>/` with a letter git uses as a prefix.
        case letter(Character)
    }

    /// Letters git uses as diff prefixes: a/b by default (swapped by -R),
    /// c/i/o/w under diff.mnemonicPrefix.
    private static let prefixLetters: Set<Character> = ["a", "b", "c", "i", "o", "w"]

    /// Extracts the path from the payload of a `+++ ` header line.
    /// Returns nil for `/dev/null` (deleted file).
    ///
    /// A single-letter git prefix is stripped only when the paired `--- `
    /// header doesn't contradict it: real git prefix pairs always use two
    /// different letters, so the same letter on both sides means a genuine
    /// directory in `--no-prefix` output and is kept.
    static func parseFileHeaderPath(
        _ payload: String,
        pairedWith oldSide: HeaderPathPrefix = .unknown
    ) -> String? {
        let text = Self.normalizedHeaderPath(payload)
        if text == "/dev/null" { return nil }
        if let letter = Self.prefixLetter(of: text), Self.stripsPrefix(letter, pairedWith: oldSide) {
            let stripped = text.dropFirst(2)
            return stripped.isEmpty ? nil : String(stripped)
        }
        return text.isEmpty ? nil : String(text)
    }

    static func headerPrefixClass(of payload: String) -> HeaderPathPrefix {
        let text = Self.normalizedHeaderPath(payload)
        if text == "/dev/null" { return .devNull }
        if let letter = Self.prefixLetter(of: text) { return .letter(letter) }
        return .bare
    }

    /// Strips a tab-appended trailer (e.g. a timestamp) and undoes quoting.
    private static func normalizedHeaderPath(_ payload: String) -> Substring {
        // Keep empty subsequences so a bare header cannot crash the
        // subscript; the empty result falls through to the nil returns above.
        var text = payload.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
        if text.hasPrefix("\"") {
            text = Substring(unquote(String(text)))
        }
        return text
    }

    private static func prefixLetter(of text: Substring) -> Character? {
        guard let first = text.first, prefixLetters.contains(first),
              text.dropFirst().first == "/"
        else { return nil }
        return first
    }

    private static func stripsPrefix(_ letter: Character, pairedWith oldSide: HeaderPathPrefix) -> Bool {
        switch oldSide {
        case .unknown, .devNull: true
        case .bare: false
        case .letter(let oldLetter): oldLetter != letter
        }
    }

    struct HunkHeader {
        var newStart: Int
        var oldCount: Int
        var newCount: Int
    }

    /// Upper bound for hunk starts and counts (~2.8e14). Real files are many
    /// orders of magnitude smaller; anything larger is corrupt input.
    static let maxLineNumber = 1 << 48

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@ ...`.
    static func parseHunkHeader(_ line: ArraySlice<UInt8>) -> HunkHeader? {
        var index = line.startIndex

        func expect(_ text: String) -> Bool {
            for byte in text.utf8 {
                guard index < line.endIndex, line[index] == byte else { return false }
                index += 1
            }
            return true
        }

        func parseInt() -> Int? {
            let zero = UInt8(ascii: "0")
            let nine = UInt8(ascii: "9")
            var value = 0
            var sawDigit = false
            while index < line.endIndex, (zero...nine).contains(line[index]) {
                // Checked accumulation: an absurd digit run (corrupt input)
                // must reject the header, not trap the process.
                let (shifted, multiplyOverflowed) = value.multipliedReportingOverflow(by: 10)
                let (sum, addOverflowed) = shifted.addingReportingOverflow(Int(line[index] - zero))
                guard !multiplyOverflowed, !addOverflowed else { return nil }
                value = sum
                sawDigit = true
                index += 1
            }
            // Cap well below Int.max so downstream line arithmetic
            // (newLine += 1, range merging) can never overflow.
            guard sawDigit, value <= Self.maxLineNumber else { return nil }
            return value
        }

        func parseOptionalCount() -> Int? {
            guard index < line.endIndex, line[index] == UInt8(ascii: ",") else { return 1 }
            index += 1
            return parseInt()
        }

        guard expect("@@ -"), parseInt() != nil, let oldCount = parseOptionalCount(),
              expect(" +"), let newStart = parseInt(), let newCount = parseOptionalCount(),
              expect(" @@")
        else { return nil }
        return HunkHeader(newStart: newStart, oldCount: oldCount, newCount: newCount)
    }

    /// Undoes C-style quoting git applies to paths containing special
    /// characters (spaces are not quoted, but e.g. UTF-8 and control
    /// characters are): `"a\303\244.swift"` → `aä.swift`.
    ///
    /// Deliberately a single branchy state machine (complexity above the
    /// lint threshold): splitting the escape table across helpers would
    /// obscure it.
    static func unquote(_ quoted: String) -> String { // swiftlint:disable:this cyclomatic_complexity
        guard quoted.hasPrefix("\""), quoted.hasSuffix("\""), quoted.count >= 2 else {
            return quoted
        }
        var bytes: [UInt8] = []
        var iterator = quoted.dropFirst().dropLast().utf8.makeIterator()
        var pending: [UInt8] = []

        func next() -> UInt8? {
            if pending.isEmpty { return iterator.next() }
            return pending.removeFirst()
        }

        while let byte = next() {
            guard byte == UInt8(ascii: "\\") else {
                bytes.append(byte)
                continue
            }
            guard let escaped = next() else { break }
            switch escaped {
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "\""): bytes.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Up to three octal digits.
                var value = UInt32(escaped - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, let digit = next() {
                    if (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) {
                        value = value * 8 + UInt32(digit - UInt8(ascii: "0"))
                        digits += 1
                    } else {
                        pending.append(digit)
                        break
                    }
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default:
                bytes.append(escaped)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension ChangedLines {
    /// Parses a complete unified diff held in memory. For large inputs,
    /// prefer feeding chunks to a `DiffParser` instead.
    public init(diff: String) {
        var parser = DiffParser()
        parser.consume(diff)
        self = parser.finalize()
    }
}
