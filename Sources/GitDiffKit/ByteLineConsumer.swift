/// Chunk-to-line plumbing for the streaming diff parser.
///
/// Chunks may be split at arbitrary byte offsets — including in the middle
/// of a line or of a multi-byte UTF-8 character. Splitting happens on the
/// `\n` byte, which is unambiguous in UTF-8 (0x0A never occurs inside a
/// multi-byte sequence), and a partial trailing line is carried over to the
/// next chunk. A trailing `\r` is stripped so CRLF input parses identically,
/// and recorded so it can be rendered back.
protocol ByteLineConsumer {
    /// The partial line carried across chunk boundaries.
    var carry: LineCarry { get set }

    /// Called once per complete line.
    mutating func processLine(_ line: RawLine)
}

/// One input line as the splitter hands it on.
struct RawLine {
    /// The line without its terminator or trailing `\r`, cut to the cap.
    var bytes: ArraySlice<UInt8>
    var endsWithCarriageReturn: Bool
    /// Whether the line, without its `\r`, was longer than the cap.
    var isTruncated: Bool
    /// False only for a final line that has no `\n`.
    var isTerminated: Bool
}

/// The start of a line that a chunk boundary split, capped at the line
/// length limit, with what the cap hid: the real last byte and whether
/// bytes were dropped. Both flags therefore come out the same for any
/// chunking.
struct LineCarry: Sendable {
    /// Lines are processed truncated to this many bytes, so one unterminated
    /// or absurd line cannot grow the carry buffer without bound. The cap is
    /// applied to whole and split lines alike.
    let maximumLength: Int
    var bytes: [UInt8] = []
    /// Separate from `bytes.isEmpty`, which a zero cap keeps empty.
    var isPending = false
    var lastByte: UInt8 = 0
    /// Bytes dropped past the cap, saturating at 2: enough to tell a line
    /// whose only excess is its `\r` from a truncated one.
    var droppedBytes = 0

    init(maximumLength: Int) {
        self.maximumLength = max(0, maximumLength)
    }
}

extension ByteLineConsumer {
    mutating func consumeChunk(_ chunk: ArraySlice<UInt8>) {
        let newline = UInt8(ascii: "\n")
        var start = chunk.startIndex
        while let terminator = chunk[start...].firstIndex(of: newline) {
            if carry.isPending {
                appendToCarry(chunk[start..<terminator])
                flushCarry(isTerminated: true)
            } else {
                processLine(Self.rawLine(chunk[start..<terminator], maximumLength: carry.maximumLength))
            }
            start = chunk.index(after: terminator)
        }
        if start < chunk.endIndex {
            appendToCarry(chunk[start...])
        }
    }

    /// Flushes an unterminated final line. Call once, when input is done.
    mutating func flushPartialLine() {
        guard carry.isPending else { return }
        flushCarry(isTerminated: false)
    }

    /// A line that lies whole inside one chunk.
    static func rawLine(_ line: ArraySlice<UInt8>, maximumLength: Int) -> RawLine {
        let endsWithCarriageReturn = line.last == UInt8(ascii: "\r")
        let logical = endsWithCarriageReturn ? line.dropLast() : line
        return RawLine(
            bytes: logical.prefix(maximumLength),
            endsWithCarriageReturn: endsWithCarriageReturn,
            isTruncated: logical.count > maximumLength,
            isTerminated: true
        )
    }

    private mutating func appendToCarry(_ bytes: ArraySlice<UInt8>) {
        guard let last = bytes.last else { return }
        carry.isPending = true
        carry.lastByte = last
        let room = carry.maximumLength - carry.bytes.count
        carry.bytes.append(contentsOf: bytes.prefix(room))
        if bytes.count > room {
            carry.droppedBytes = min(2, carry.droppedBytes + min(2, bytes.count - room))
        }
    }

    private mutating func flushCarry(isTerminated: Bool) {
        // Swapped out rather than copied, so the buffer is reused without
        // a copy-on-write allocation per carried line.
        var line: [UInt8] = []
        swap(&line, &carry.bytes)
        let endsWithCarriageReturn = carry.lastByte == UInt8(ascii: "\r")
        // With a `\r` and nothing dropped, the `\r` is the carry's last
        // byte; with bytes dropped, it was among them.
        let bytes = endsWithCarriageReturn && carry.droppedBytes == 0 ? line.dropLast() : line[...]
        let isTruncated = carry.droppedBytes > (endsWithCarriageReturn ? 1 : 0)
        carry.isPending = false
        carry.droppedBytes = 0
        processLine(RawLine(
            bytes: bytes,
            endsWithCarriageReturn: endsWithCarriageReturn,
            isTruncated: isTruncated,
            isTerminated: isTerminated
        ))
        line.removeAll(keepingCapacity: true)
        swap(&line, &carry.bytes)
    }
}
