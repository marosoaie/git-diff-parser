/// Writes the full model back as unified diff text into a buffer, handing
/// it on in chunks.
///
/// A flush keeps the buffer's last byte back, so a diff whose input ended
/// mid-line can drop its final `\n` however the chunks fell.
struct DiffTextWriter {
    /// About 64 KiB per chunk: few calls per megabyte, and a buffer that
    /// stays in cache.
    static let defaultChunkSize = 1 << 16

    /// A flush happens once the buffer holds this many bytes, before the
    /// next line goes in, so a chunk can run over by one line.
    let chunkSize: Int
    /// What is written and not yet handed on.
    private(set) var text: [UInt8] = []

    init(chunkSize: Int = defaultChunkSize) {
        self.chunkSize = max(1, chunkSize)
    }

    /// Writes `diff`, handing every full chunk to `write`; what is left is
    /// in `text`.
    mutating func append(_ diff: Diff, flushingTo write: (ArraySlice<UInt8>) throws -> Void) rethrows {
        try diff.preamble.forEach { line in
            try flushIfFull(write)
            append(line)
        }
        try diff.files.forEach { try append($0, flushingTo: write) }
        if diff.hasNoNewlineAtEnd, text.last == Self.newline {
            text.removeLast()
        }
    }

    /// The file in input order: raw header, binary patch lines, leading
    /// lines, then each hunk with its trailing lines.
    private mutating func append(_ file: DiffFile, flushingTo write: (ArraySlice<UInt8>) throws -> Void) rethrows {
        try flushIfFull(write)
        text.append(contentsOf: file.rawHeader)
        try file.binaryPatchLines.forEach { line in
            try flushIfFull(write)
            append(line)
        }
        try file.leadingLines.forEach { line in
            try flushIfFull(write)
            append(line)
        }
        try file.hunks.forEach { hunk in
            try flushIfFull(write)
            append(hunk.header, heading: hunk.heading)
            try hunk.lines.forEach { line in
                try flushIfFull(write)
                append(line)
            }
            try hunk.trailingLines.forEach { line in
                try flushIfFull(write)
                append(line)
            }
        }
    }

    /// Hands on all but the buffer's last byte once it holds a chunk, never
    /// an empty one.
    private mutating func flushIfFull(_ write: (ArraySlice<UInt8>) throws -> Void) rethrows {
        guard text.count >= chunkSize, text.count > 1 else { return }
        try write(text[..<(text.count - 1)])
        let last = text[text.count - 1]
        text.removeAll(keepingCapacity: true)
        text.append(last)
    }

    private mutating func append(_ line: DiffTextLine) {
        text.append(contentsOf: line.content)
        endLine(withCarriageReturn: line.endsWithCarriageReturn)
    }

    /// `@@ -oldStart[,oldCount] +newStart[,newCount] @@heading`, leaving a
    /// count out only where it is 1, so the line always says what the
    /// header holds.
    private mutating func append(_ header: HunkHeader, heading: ArraySlice<UInt8>) {
        text.append(contentsOf: Self.hunkOpening)
        appendRange(start: header.oldStart, count: header.oldCount, countIsImplicit: header.oldCountIsImplicit)
        text.append(contentsOf: Self.hunkNewSide)
        appendRange(start: header.newStart, count: header.newCount, countIsImplicit: header.newCountIsImplicit)
        text.append(contentsOf: Self.hunkClosing)
        text.append(contentsOf: heading)
        endLine(withCarriageReturn: header.endsWithCarriageReturn)
    }

    private mutating func appendRange(start: Int, count: Int, countIsImplicit: Bool) {
        text.append(contentsOf: String(start).utf8)
        guard !countIsImplicit || count != 1 else { return }
        text.append(UInt8(ascii: ","))
        text.append(contentsOf: String(count).utf8)
    }

    /// The marker is left out only for a context line, so a hand-built
    /// addition or deletion flagged `hasNoMarker` still says what it is.
    private mutating func append(_ line: DiffLine) {
        if !line.info.hasNoMarker || line.info.kind != .context {
            text.append(Self.marker(of: line.info.kind))
        }
        text.append(contentsOf: line.content)
        endLine(withCarriageReturn: line.info.endsWithCarriageReturn)
        if line.hasNoNewlineAtEnd {
            text.append(contentsOf: Self.noNewlineMarker)
            endLine(withCarriageReturn: line.noNewlineMarkerEndsWithCarriageReturn)
        }
    }

    private mutating func endLine(withCarriageReturn carriageReturn: Bool) {
        if carriageReturn {
            text.append(UInt8(ascii: "\r"))
        }
        text.append(Self.newline)
    }

    private static func marker(of kind: LineInfo.Kind) -> UInt8 {
        switch kind {
        case .context: UInt8(ascii: " ")
        case .addition: UInt8(ascii: "+")
        case .deletion: UInt8(ascii: "-")
        }
    }

    private static let newline = UInt8(ascii: "\n")
    private static let hunkOpening = Array("@@ -".utf8)
    private static let hunkNewSide = Array(" +".utf8)
    private static let hunkClosing = Array(" @@".utf8)
    /// Git's wording, which it never localizes.
    private static let noNewlineMarker = Array("\\ No newline at end of file".utf8)
}
