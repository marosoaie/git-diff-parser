import Foundation

/// Shared chunk-to-line plumbing for the streaming parsers.
///
/// Chunks may be split at arbitrary byte offsets — including in the middle
/// of a line or of a multi-byte UTF-8 character. Splitting happens on the
/// `\n` byte, which is unambiguous in UTF-8 (0x0A never occurs inside a
/// multi-byte sequence), and a partial trailing line is carried over to the
/// next chunk. A trailing `\r` is stripped so CRLF input parses identically.
package protocol ByteLineConsumer {
    /// Partial line carried across chunk boundaries.
    var partialLine: [UInt8] { get set }

    /// Called once per complete line, without the terminator.
    mutating func processLine(_ line: ArraySlice<UInt8>)
}

extension ByteLineConsumer {
    /// Lines are processed truncated to this many bytes, so one unterminated
    /// or absurd line cannot grow the carry buffer without bound. The cap is
    /// applied to whole and split lines alike, keeping results
    /// chunking-independent.
    package static var maxLineBytes: Int { 1 << 20 }

    package mutating func consumeChunk(_ chunk: ArraySlice<UInt8>) {
        let newline = UInt8(ascii: "\n")
        var start = chunk.startIndex
        while let terminator = chunk[start...].firstIndex(of: newline) {
            if partialLine.isEmpty {
                processTrimmedLine(chunk[start..<terminator])
            } else {
                appendCapped(chunk[start..<terminator])
                let line = partialLine
                partialLine.removeAll(keepingCapacity: true)
                processTrimmedLine(line[...])
            }
            start = chunk.index(after: terminator)
        }
        if start < chunk.endIndex {
            appendCapped(chunk[start...])
        }
    }

    /// Flushes an unterminated final line. Call once, when input is done.
    package mutating func flushPartialLine() {
        guard !partialLine.isEmpty else { return }
        let line = partialLine
        partialLine.removeAll(keepingCapacity: false)
        processTrimmedLine(line[...])
    }

    private mutating func appendCapped(_ bytes: ArraySlice<UInt8>) {
        let room = Self.maxLineBytes - partialLine.count
        guard room > 0 else { return }
        partialLine.append(contentsOf: bytes.prefix(room))
    }

    private mutating func processTrimmedLine(_ line: ArraySlice<UInt8>) {
        let capped = line.prefix(Self.maxLineBytes)
        if capped.last == UInt8(ascii: "\r") {
            processLine(capped.dropLast())
        } else {
            processLine(capped)
        }
    }
}
