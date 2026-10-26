extension DiffEventParser {
    /// Starts a hunk at its `@@` line; outside a file, it is counted so its
    /// content can't be read as headers, but sends no events.
    mutating func beginHunk(_ line: RawLine) {
        if case .combined(_, let parents) = file {
            return beginCombinedHunk(line, parents: parents)
        }
        guard let parsed = HunkHeader.parse(line.bytes) else {
            report(.malformedHunkHeader)
            return unrecognized(line)
        }
        let isOpen = if case .open = file { true } else { false }
        hunk.remainingOld = parsed.header.oldCount
        hunk.remainingNew = parsed.header.newCount
        hunk.oldLine = parsed.header.oldStart
        hunk.newLine = parsed.header.newStart
        hunk.emitsEvents = isOpen
        hunk.reportsDamage = isOpen
        hunk.isCombined = false
        if isOpen {
            var header = parsed.header
            header.endsWithCarriageReturn = line.endsWithCarriageReturn
            let heading = parsed.heading
            consumer.beginHunk(header, heading: heading.span)
        } else if case .none = file {
            report(.hunkWithoutFile)
        }
    }

    /// One line inside a hunk. Each marker must have budget on its own side,
    /// or a malformed hunk could invent lines its counts never promised (a
    /// `+` in a deletion-only hunk); a line the budgets can't absorb ends
    /// the hunk and is read again outside it, so a corrupted count can't
    /// swallow the next file's headers.
    ///
    /// One flat switch on the marker byte (complexity above the lint
    /// threshold): it runs for every content line, and splitting it would
    /// add a call per line on the hottest path.
    mutating func processHunkLine(_ line: RawLine) { // swiftlint:disable:this cyclomatic_complexity
        let bytes = line.bytes
        switch bytes.first {
        case UInt8(ascii: "+"):
            guard hunk.remainingNew > 0 else { return endHunkEarly(line) }
            emit(.addition, content: bytes.dropFirst(), of: line)
            hunk.newLine += 1
            hunk.remainingNew -= 1
        case UInt8(ascii: "-"):
            guard hunk.remainingOld > 0 else { return endHunkEarly(line) }
            emit(.deletion, content: bytes.dropFirst(), of: line)
            hunk.oldLine += 1
            hunk.remainingOld -= 1
        case UInt8(ascii: " "):
            guard hunk.remainingOld > 0, hunk.remainingNew > 0 else { return endHunkEarly(line) }
            emitContext(content: bytes.dropFirst(), of: line)
        case UInt8(ascii: "\\"):
            if !takeNoNewlineMarker(line), hunk.reportsDamage {
                report(.misplacedNoNewlineMarker)
            }
        case UInt8(ascii: "d") where bytes.starts(with: DiffSyntax.diffPrefix):
            // Well-formed content always has a marker, so a `diff ` line
            // mid-hunk means the hunk was truncated.
            endHunkEarly(line)
        default:
            // Trailing-whitespace stripping turns " " into "", so any other
            // line is context, as `git apply` takes it.
            guard hunk.remainingOld > 0, hunk.remainingNew > 0 else { return endHunkEarly(line) }
            if !bytes.isEmpty, hunk.reportsDamage {
                report(.missingLineMarker)
            }
            emitContext(content: bytes, of: line, hasNoMarker: true)
        }
    }

    private mutating func emitContext(content: ArraySlice<UInt8>, of line: RawLine, hasNoMarker: Bool = false) {
        emit(.context, content: content, of: line, hasNoMarker: hasNoMarker)
        hunk.oldLine += 1
        hunk.newLine += 1
        hunk.remainingOld -= 1
        hunk.remainingNew -= 1
    }

    private mutating func emit(
        _ kind: LineInfo.Kind, content: ArraySlice<UInt8>, of line: RawLine, hasNoMarker: Bool = false
    ) {
        hunk.lastContentLine = lineNumber
        guard hunk.emitsEvents else { return }
        let info = LineInfo(
            kind: kind,
            oldNumber: kind == .addition ? nil : hunk.oldLine,
            newNumber: kind == .deletion ? nil : hunk.newLine,
            endsWithCarriageReturn: line.endsWithCarriageReturn,
            isTruncated: line.isTruncated,
            hasNoMarker: hasNoMarker
        )
        consumer.line(info, content: content.span)
    }

    /// Takes `marker`, a `\ No newline at end of file` line, if it directly
    /// follows a content line; the event goes out only if that line's did.
    mutating func takeNoNewlineMarker(_ marker: RawLine) -> Bool {
        guard hunk.lastContentLine == lineNumber - 1 else { return false }
        hunk.lastContentLine = -1
        if hunk.emitsEvents {
            consumer.noNewlineAtEndOfFile(endsWithCarriageReturn: marker.endsWithCarriageReturn)
        }
        return true
    }

    /// Ends a hunk whose counts aren't used up and reads `line` again
    /// outside it.
    mutating func endHunkEarly(_ line: RawLine) {
        endHunkCutShort()
        processOutsideHunk(line)
    }

    mutating func endHunkCutShort() {
        if hunk.reportsDamage {
            report(.hunkCutShort)
        }
        hunk.close()
    }
}
