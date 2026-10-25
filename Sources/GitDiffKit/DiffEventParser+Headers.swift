extension DiffEventParser {
    /// Ends the current file and opens a header block at its `diff ` line.
    mutating func startFile(diffLine line: RawLine) {
        endFile()
        rawHeader.removeAll(keepingCapacity: true)
        header = HeaderBlock(parser: FileHeaderParser(diffLine: line.bytes))
        appendToHeader(line)
    }

    /// Ends the current file and opens a plain diff's header block at its
    /// `---`/`+++` pair.
    mutating func startPlainFile(oldSide: RawLine, newSide: RawLine) {
        endFile()
        rawHeader.removeAll(keepingCapacity: true)
        header = HeaderBlock(parser: FileHeaderParser())
        // The old side was read a line ago, so its damage belongs there.
        lineNumber -= 1
        _ = continueHeader(oldSide)
        lineNumber += 1
        _ = continueHeader(newSide)
    }

    /// Feeds a line to the open header block. Returns whether the line was
    /// used up: a header line, or a binary marker, which ends the block.
    /// Any other line ends the block and is left to the caller.
    mutating func continueHeader(_ line: RawLine) -> Bool {
        guard let result = header?.parser.consume(line.bytes) else { return false }
        if result != .notHeader {
            if result == .valueIgnored, let block = header, !block.isAbandoned {
                report(.ignoredHeaderValue, file: block.parser.header(isBinary: false, parents: 0))
            }
            appendToHeader(line)
            return true
        }
        let isBinary = DiffSyntax.isBinaryMarker(line.bytes)
        if isBinary {
            appendToHeader(line)
        }
        guard let block = header else { return false }
        header = nil
        deliverHeader(block, isBinary: isBinary, endingAt: line)
        if isBinary, line.bytes.elementsEqual(DiffSyntax.binaryPatchMarker), file.hasBegun {
            binaryPatch = .expectingFirstPart
        }
        return isBinary
    }

    /// Buffers a header block line verbatim, abandoning the file once the
    /// block outgrows its bounds.
    private mutating func appendToHeader(_ line: RawLine) {
        guard let block = header, !block.isAbandoned else { return }
        let size = line.bytes.count + (line.endsWithCarriageReturn ? 1 : 0) + (line.isTerminated ? 1 : 0)
        guard !line.isTruncated,
              block.lineCount < DiffSyntax.maximumHeaderLines,
              rawHeader.count + size <= DiffSyntax.maximumHeaderBytes
        else {
            report(.headerTooLarge, file: block.parser.header(isBinary: false, parents: 0))
            header?.isAbandoned = true
            rawHeader.removeAll(keepingCapacity: true)
            return
        }
        header?.lineCount += 1
        rawHeader.append(contentsOf: line.bytes)
        if line.endsWithCarriageReturn {
            rawHeader.append(UInt8(ascii: "\r"))
        }
        if line.isTerminated {
            rawHeader.append(UInt8(ascii: "\n"))
        }
    }

    /// Opens the file a finished header block describes and sends
    /// `beginFile`; `line` is the line that ended the block, if any.
    mutating func deliverHeader(_ block: HeaderBlock, isBinary: Bool, endingAt line: RawLine?) {
        guard !block.isAbandoned else {
            // `.abandoned` counts hunks as `@@` ones, which a combined
            // file's `@@@` hunks aren't: their columns could fake a file.
            file = block.parser.isCombined ? .skippingToNextDiffLine : .abandoned
            return
        }
        let fileHeader: FileHeader
        if block.parser.isCombined {
            let parents = Self.parentCount(of: block.parser, endingAt: line)
            guard parents <= DiffSyntax.maximumParents else {
                report(.tooManyParents, file: block.parser.header(isBinary: isBinary, parents: parents))
                file = .skippingToNextDiffLine
                return
            }
            fileHeader = block.parser.header(isBinary: isBinary, parents: parents)
            file = .combined(fileHeader, parents: parents)
        } else {
            fileHeader = block.parser.header(isBinary: isBinary, parents: 0)
            file = .open(fileHeader)
        }
        let raw = rawHeader
        consumer.beginFile(fileHeader, rawHeader: raw.span)
    }

    /// A combined diff's parent count: one less than the `@` run of the
    /// hunk header that ends its header block, else what its `index` or
    /// `mode` line lists, else 2.
    private static func parentCount(of parser: FileHeaderParser, endingAt line: RawLine?) -> Int {
        // Counting stops past the cap, so a hostile run of `@` costs nothing.
        let atSigns = line?.bytes.prefix(DiffSyntax.maximumParents + 2).prefix { $0 == UInt8(ascii: "@") }.count ?? 0
        if atSigns >= 3 {
            return atSigns - 1
        }
        return parser.parentCountHint ?? 2
    }

    /// Feeds a line to an open `GIT binary patch` block. Returns false, and
    /// closes the block, for a line that doesn't belong to it.
    mutating func continueBinaryPatch(_ line: RawLine) -> Bool {
        guard let position = binaryPatch else { return false }
        let bytes = line.bytes
        let startsPart = bytes.starts(with: DiffSyntax.literalPrefix) || bytes.starts(with: DiffSyntax.deltaPrefix)
        switch position {
        case .expectingFirstPart where startsPart, .betweenParts where startsPart:
            binaryPatch = .inPart
        case .inPart where bytes.isEmpty:
            binaryPatch = .betweenParts
        case .inPart where bytes.first.map(DiffSyntax.isBase85LengthByte) == true:
            break
        default:
            binaryPatch = nil
            if position != .betweenParts {
                report(.malformedBinaryPatch)
            }
            return false
        }
        consumer.binaryPatchLine(bytes.span, endsWithCarriageReturn: line.endsWithCarriageReturn)
        return true
    }
}
