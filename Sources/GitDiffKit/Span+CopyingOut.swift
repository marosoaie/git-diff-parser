extension Array where Element == UInt8 {
    /// Creates an array holding a copy of the bytes in `span`.
    ///
    /// Event payloads are spans of the parser's buffers, valid only during
    /// the callback; copy them out with this to keep them.
    public init(copying span: Span<UInt8>) {
        self = (0..<span.count).map { span[$0] }
    }
}

extension String {
    /// Creates a string by decoding `span` as UTF-8, replacing invalid
    /// bytes with U+FFFD, the way `String(decoding:as:)` does.
    ///
    /// Two different byte sequences can decode to the same string, so
    /// compare the bytes when identity matters.
    public init(decodingLossily span: Span<UInt8>) {
        if let valid = try? UTF8Span(validating: span) {
            self.init(copying: valid)
        } else {
            self.init(decoding: [UInt8](copying: span), as: UTF8.self)
        }
    }
}
