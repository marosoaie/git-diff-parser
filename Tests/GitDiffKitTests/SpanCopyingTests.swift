import Testing
import GitDiffKit

@Suite("Span copy-out conveniences")
struct SpanCopyingTests {
    @Test("copying a span yields exactly its bytes, empty or not", arguments: [[], [0x00, 0xFF, 0x0A], Array(0...255)])
    func copiesBytes(bytes: [UInt8]) {
        #expect([UInt8](copying: bytes.span) == bytes)
    }

    @Test("a slice's span copies only the slice")
    func copiesSlice() {
        let bytes: [UInt8] = [1, 2, 3, 4, 5]
        let middle = bytes[1..<4]
        #expect([UInt8](copying: middle.span) == [2, 3, 4])
    }

    @Test("valid UTF-8 decodes unchanged")
    func decodesValidUTF8() {
        let text = "café ✓ 𝄞"
        #expect(String(decodingLossily: Array(text.utf8).span) == text)
    }

    @Test("invalid UTF-8 decodes with replacement characters, like String(decoding:as:)")
    func decodesInvalidUTF8Lossily() {
        let bytes: [UInt8] = [0x61, 0xFF, 0x62, 0xC3]
        #expect(String(decodingLossily: bytes.span) == "a\u{FFFD}b\u{FFFD}")
        #expect(String(decodingLossily: bytes.span) == String(decoding: bytes, as: UTF8.self))
    }
}
