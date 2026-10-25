/// Streaming parser that turns a diff into `DiffEventConsumer` events.
///
/// Feed it the diff in byte chunks of any size, split anywhere — even
/// inside a line or a UTF-8 character — and call `finalize()` once at the
/// end. The events are the same for any chunking. Working memory is
/// bounded by the line cap (`ParsingOptions.maximumLineLength`) and the
/// header bound (64 lines, 1 MiB), not by the size of the input.
///
///     var parser = DiffEventParser(consumer: MyCollector())
///     while let chunk = readSomeBytes() { parser.consume(chunk) }
///     let collector = parser.finalize()
///
/// It reads `git diff`/`git show` output with git's extended headers,
/// plain `diff -u`/`diff -ruN` output, and streams such as `git log -p` or
/// `git format-patch` mail, whose commit text arrives as unrecognized lines.
/// Line endings are `\n`; a `\r` before it is stripped and flagged, so CRLF
/// input parses like LF input.
///
/// Combined diffs of merges (`diff --cc`, `diff --combined`) are
/// recognized and skipped: each file gets `beginFile` (format `.combined`)
/// and `endFile`, but its hunks produce no events. For the lines a merge
/// changed, diff it against its first parent (`--diff-merges=first-parent`).
///
/// Damaged input never traps or throws: the parser recovers locally or
/// abandons the damaged file, and reports either through `damage(_:)`.
public struct DiffEventParser<Consumer: DiffEventConsumer>: ByteLineConsumer {
    /// The consumer receiving the events.
    public var consumer: Consumer

    var carry: LineCarry
    /// The 1-based number of the line being processed.
    var lineNumber = 0
    /// The open header block, if any.
    var header: HeaderBlock?
    /// The open header block's lines, verbatim; reused across files.
    var rawHeader: [UInt8] = []
    /// A `--- ` line outside a header block, kept for one line to see
    /// whether a `+++ ` pairs with it.
    var pendingOldSide: RawLine?
    var file: FileState = .none
    /// Where a `GIT binary patch` block is, while one is open.
    var binaryPatch: BinaryPatchPosition?
    var hunk = HunkState()

    /// Creates a parser that sends its events to `consumer`.
    public init(consumer: Consumer, options: ParsingOptions = .init()) {
        self.consumer = consumer
        carry = LineCarry(maximumLength: options.maximumLineLength)
    }

    // MARK: Input

    /// Feeds the next chunk of the diff; it may end mid-line.
    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        consumeChunk(chunk)
    }

    /// Feeds the next chunk of the diff; it may end mid-line.
    public mutating func consume(_ chunk: [UInt8]) {
        consumeChunk(chunk[...])
    }

    /// Feeds the next chunk of the diff as UTF-8 text; it may end mid-line.
    public mutating func consume(_ text: String) {
        consumeChunk(Array(text.utf8)[...])
    }

    /// Flushes an unterminated final line, ends the open hunk and file, and
    /// returns the consumer.
    public mutating func finalize() -> Consumer {
        flushPartialLine()
        // Damage found from here on is reported one past the last line.
        lineNumber += 1
        if let oldSide = pendingOldSide {
            pendingOldSide = nil
            unrecognized(oldSide)
        }
        if hunk.isOpen {
            endHunkCutShort()
        }
        endFile()
        lineNumber -= 1
        return consumer
    }

    // MARK: Lines

    mutating func processLine(_ line: RawLine) {
        lineNumber += 1
        if hunk.isOpen {
            if hunk.isCombined {
                processCombinedHunkLine(line)
            } else {
                processHunkLine(line)
            }
        } else {
            processOutsideHunk(line)
        }
    }

    /// A line between hunks: a header, a hunk header, or something the
    /// parser passes on unrecognized.
    mutating func processOutsideHunk(_ line: RawLine) {
        let bytes = line.bytes
        if let oldSide = pendingOldSide {
            pendingOldSide = nil
            if bytes.starts(with: DiffSyntax.newSidePrefix) {
                return startPlainFile(oldSide: oldSide, newSide: line)
            }
            unrecognized(oldSide)
        }
        if bytes.starts(with: DiffSyntax.diffPrefix) {
            return startFile(diffLine: line)
        }
        if continueHeader(line) || continueBinaryPatch(line) {
            return
        }
        if case .skippingToNextDiffLine = file {
            return
        }
        if bytes.starts(with: DiffSyntax.oldSidePrefix), !file.isCombined {
            // A plain diff's file starts at a `---`/`+++` pair, as in
            // `git apply`; a combined file's hunks could fake one.
            pendingOldSide = line
        } else if bytes.starts(with: DiffSyntax.hunkPrefix) {
            beginHunk(line)
        } else if bytes.first == UInt8(ascii: "\\"), takeNoNewlineMarker() {
            return
        } else if file.hasBegun, bytes.starts(with: DiffSyntax.noNewlinePrefix) {
            // A duplicate, or one before the first hunk. Outside a file,
            // such a line is text, as in a format-patch commit message.
            report(.misplacedNoNewlineMarker)
        } else {
            unrecognized(line)
        }
    }

    mutating func unrecognized(_ line: RawLine) {
        guard !file.dropsLines else { return }
        let bytes = line.bytes
        consumer.unrecognizedLine(bytes.span, endsWithCarriageReturn: line.endsWithCarriageReturn)
    }

    /// Reports damage at the current line, against `header` or else the
    /// current file; an abandoned file reports nothing more.
    mutating func report(_ reason: DamageReport.Reason, file header: FileHeader? = nil) {
        guard !file.dropsLines else { return }
        consumer.damage(DamageReport(reason: reason, lineNumber: lineNumber, file: header ?? file.header))
    }

    /// Delivers an open header block and ends the current file.
    mutating func endFile() {
        if let block = header {
            header = nil
            deliverHeader(block, isBinary: false, endingAt: nil)
        }
        if let position = binaryPatch {
            binaryPatch = nil
            if position != .betweenParts {
                report(.malformedBinaryPatch)
            }
        }
        if file.hasBegun {
            consumer.endFile()
        }
        file = .none
    }
}

extension DiffEventParser: Sendable where Consumer: Sendable {}
