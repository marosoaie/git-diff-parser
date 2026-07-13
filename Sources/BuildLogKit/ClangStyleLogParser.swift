import Foundation
import StreamParsing

/// Streaming parser for the de-facto standard clang diagnostic format, the
/// common denominator emitted by swiftc, xcodebuild, SwiftLint, SwiftFormat,
/// and clang-tidy:
///
///     /path/to/File.swift:42:13: warning: variable 'x' was never used
///     Sources/App/File.swift:10: error: something bad
///
/// This is the right parser when the log's origin is mixed or unknown. When
/// you know which tool produced the log, prefer `XcodeLogParser`,
/// `SwiftLintLogParser`, or `SwiftFormatLogParser` — same recognition, plus
/// extraction of the violated rule into `Diagnostic.rule`.
///
/// A cheap byte-level scan for a severity marker gates the per-line regex,
/// so multi-gigabyte logs that are mostly non-diagnostic noise parse
/// quickly.
public struct ClangStyleLogParser: LogParsing, ByteLineConsumer {
    package var partialLine: [UInt8] = []

    private var diagnostics: [Diagnostic] = []
    private var seen = Set<String>()

    /// Tool-specific post-processing (rule extraction, message cleanup)
    /// applied to each raw diagnostic before deduplication.
    private let refine: (@Sendable (Diagnostic) -> Diagnostic)?

    // path : line [: column] : severity : message
    // The path is everything up to the first ":<digits>:" group, so paths
    // containing spaces work. `remark:` is emitted by some clang passes and
    // mapped to `note`; `fatal error:` is clang's missing-include severity.
    private let diagnosticRegex =
        /^(?<path>[^:\n][^\n]*?):(?<line>\d+)(?::(?<column>\d+))?:\s*(?<severity>fatal error|error|warning|note|remark):\s*(?<message>.*)$/

    private static let severityMarkers: [[UInt8]] = [
        Array("error:".utf8),
        Array("warning:".utf8),
        Array("note:".utf8),
        Array("remark:".utf8),
    ]

    public init() {
        refine = nil
    }

    package init(refine: @escaping @Sendable (Diagnostic) -> Diagnostic) {
        self.refine = refine
    }

    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        consumeChunk(chunk)
    }

    public mutating func finalize() -> [Diagnostic] {
        flushPartialLine()
        return diagnostics
    }

    package mutating func processLine(_ line: ArraySlice<UInt8>) {
        guard !line.isEmpty, containsSeverityMarker(line) else { return }

        let text = String(decoding: line, as: UTF8.self)
        guard let match = text.firstMatch(of: diagnosticRegex),
              let lineNumber = Int(match.line)
        else { return }

        let severity: Diagnostic.Severity =
            switch match.severity {
            case "error", "fatal error": .error
            case "warning": .warning
            default: .note
            }

        var diagnostic = Diagnostic(
            path: String(match.path),
            line: lineNumber,
            column: match.column.flatMap { Int($0) },
            severity: severity,
            message: String(match.message)
        )
        if let refine {
            diagnostic = refine(diagnostic)
        }

        let key = "\(diagnostic.path):\(diagnostic.line):\(diagnostic.column ?? 0):\(diagnostic.severity.rawValue):\(diagnostic.message)"
        if seen.insert(key).inserted {
            diagnostics.append(diagnostic)
        }
    }

    /// Fast pre-filter: a matching line necessarily contains one of the
    /// severity words followed by a colon.
    private func containsSeverityMarker(_ line: ArraySlice<UInt8>) -> Bool {
        // Hot path (runs per byte of the log); the first-byte comparison
        // rejects almost every position before the full starts(with:).
        line.indices.contains { index in
            Self.severityMarkers.contains { marker in
                line[index] == marker[0] && line[index...].starts(with: marker)
            }
        }
    }
}
