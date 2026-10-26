@testable import GitDiffKit

/// Records every event a parser sends, with span contents copied out, so
/// tests can assert on the whole stream and compare streams across
/// chunkings.
struct EventRecorder: DiffEventConsumer, Sendable {
    /// One callback and its arguments.
    enum Event: Sendable, Equatable, CustomStringConvertible {
        case beginFile(FileHeader, rawHeader: [UInt8])
        case beginHunk(HunkHeader, heading: [UInt8])
        case line(LineInfo, content: [UInt8])
        case noNewlineAtEndOfFile(endsWithCarriageReturn: Bool)
        case binaryPatchLine([UInt8], endsWithCarriageReturn: Bool)
        case endFile
        case unrecognizedLine([UInt8], endsWithCarriageReturn: Bool)
        case damage(DamageReport)
        case noNewlineAtEndOfInput

        var description: String {
            let text = { (bytes: [UInt8]) in String(decoding: bytes, as: UTF8.self).debugDescription }
            switch self {
            case let .beginFile(header, rawHeader):
                let path = header.newPath?.string ?? "nil"
                return "beginFile(\(header.format), \(header.change), \(path), \(text(rawHeader)))"
            case let .beginHunk(header, heading):
                let ranges = "-\(header.oldStart),\(header.oldCount) +\(header.newStart),\(header.newCount)"
                return "beginHunk(\(ranges) \(text(heading)))"
            case let .line(info, content):
                let numbers = [info.oldNumber, info.newNumber].map { $0.map(String.init) ?? "-" }
                return "line(\(info.kind), \(numbers[0])/\(numbers[1]), \(text(content)))"
            case let .noNewlineAtEndOfFile(cr):
                return "noNewlineAtEndOfFile(cr: \(cr))"
            case let .binaryPatchLine(content, cr):
                return "binaryPatchLine(\(text(content)), cr: \(cr))"
            case .endFile:
                return "endFile"
            case let .unrecognizedLine(content, cr):
                return "unrecognizedLine(\(text(content)), cr: \(cr))"
            case let .damage(report):
                return "damage(\(report.reason), line \(report.lineNumber), \(report.file?.newPath?.string ?? "nil"))"
            case .noNewlineAtEndOfInput:
                return "noNewlineAtEndOfInput"
            }
        }
    }

    var events: [Event] = []

    mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>) {
        events.append(.beginFile(header, rawHeader: [UInt8](copying: rawHeader)))
    }

    mutating func beginHunk(_ header: HunkHeader, heading: Span<UInt8>) {
        events.append(.beginHunk(header, heading: [UInt8](copying: heading)))
    }

    mutating func line(_ line: LineInfo, content: Span<UInt8>) {
        events.append(.line(line, content: [UInt8](copying: content)))
    }

    mutating func noNewlineAtEndOfFile(endsWithCarriageReturn: Bool) {
        events.append(.noNewlineAtEndOfFile(endsWithCarriageReturn: endsWithCarriageReturn))
    }

    mutating func binaryPatchLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) {
        events.append(.binaryPatchLine([UInt8](copying: content), endsWithCarriageReturn: endsWithCarriageReturn))
    }

    mutating func endFile() {
        events.append(.endFile)
    }

    mutating func unrecognizedLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool) {
        events.append(.unrecognizedLine([UInt8](copying: content), endsWithCarriageReturn: endsWithCarriageReturn))
    }

    mutating func damage(_ report: DamageReport) {
        events.append(.damage(report))
    }

    mutating func noNewlineAtEndOfInput() {
        events.append(.noNewlineAtEndOfInput)
    }

    /// The events of `bytes`, fed to a parser in `chunkSize`-byte chunks.
    static func events(
        in bytes: [UInt8], chunkSize: Int = .max, options: ParsingOptions = .init()
    ) -> [Event] {
        DiffEventParser.collect(EventRecorder(), from: bytes, chunkSize: chunkSize, options: options).events
    }

    /// The events of `diff`, fed whole.
    static func events(in diff: String, options: ParsingOptions = .init()) -> [Event] {
        events(in: Array(diff.utf8), options: options)
    }

    /// Only the damage reports among `events`.
    static func damage(in events: [Event]) -> [DamageReport] {
        events.compactMap { event in
            guard case let .damage(report) = event else { return nil }
            return report
        }
    }
}
