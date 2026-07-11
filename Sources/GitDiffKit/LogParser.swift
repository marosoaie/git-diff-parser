import Foundation

/// A single compiler/linter diagnostic extracted from a build or lint log.
public struct Diagnostic: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Codable, CaseIterable, Comparable {
        case note
        case warning
        case error

        private var rank: Int {
            switch self {
            case .note: 0
            case .warning: 1
            case .error: 2
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// Path exactly as it appeared in the log (usually absolute for Xcode
    /// and SwiftLint, relative for some other tools).
    public var path: String
    public var line: Int
    public var column: Int?
    public var severity: Severity
    public var message: String

    public init(path: String, line: Int, column: Int? = nil, severity: Severity, message: String) {
        self.path = path
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }
}

/// Streaming parser that extracts diagnostics from raw build/lint logs.
///
/// Recognizes the de-facto standard clang/swiftc format, which is also what
/// SwiftLint, clang-tidy and most C-family tools emit:
///
///     /path/to/File.swift:42:13: warning: variable 'x' was never used
///     Sources/App/File.swift:10: error: something bad
///
/// Lines that don't look like a diagnostic are ignored, so you can feed the
/// whole `xcodebuild` output straight in, chunk by chunk. A cheap byte-level
/// scan for a severity marker gates the per-line regex, so multi-gigabyte
/// logs that are mostly non-diagnostic noise parse quickly.
public struct LogParser: ByteLineConsumer {
    var partialLine: [UInt8] = []

    private var diagnostics: [Diagnostic] = []
    private var seen = Set<String>()

    // path : line [: column] : severity : message
    // The path is everything up to the first ":<digits>:" group, so paths
    // containing spaces work. `remark:` is emitted by some clang passes and
    // mapped to `note`.
    private let diagnosticRegex =
        /^(?<path>[^:\n][^\n]*?):(?<line>\d+)(?::(?<column>\d+))?:\s*(?<severity>fatal error|error|warning|note|remark):\s*(?<message>.*)$/

    private static let severityMarkers: [[UInt8]] = [
        Array("error:".utf8),
        Array("warning:".utf8),
        Array("note:".utf8),
        Array("remark:".utf8),
    ]

    public init() {}

    // MARK: Input

    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        consumeChunk(chunk)
    }

    public mutating func consume(_ chunk: [UInt8]) {
        consumeChunk(chunk[...])
    }

    public mutating func consume(_ chunk: Data) {
        consumeChunk([UInt8](chunk)[...])
    }

    public mutating func consume(_ text: String) {
        consumeChunk(Array(text.utf8)[...])
    }

    /// Flushes any unterminated final line and returns the diagnostics in
    /// log order, with exact duplicates collapsed (xcodebuild frequently
    /// prints the same diagnostic once per architecture/target).
    public mutating func finalize() -> [Diagnostic] {
        flushPartialLine()
        return diagnostics
    }

    // MARK: Per-line parsing

    mutating func processLine(_ line: ArraySlice<UInt8>) {
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

        let diagnostic = Diagnostic(
            path: String(match.path),
            line: lineNumber,
            column: match.column.flatMap { Int($0) },
            severity: severity,
            message: String(match.message)
        )

        let key = "\(diagnostic.path):\(diagnostic.line):\(diagnostic.column ?? 0):\(diagnostic.severity.rawValue):\(diagnostic.message)"
        if seen.insert(key).inserted {
            diagnostics.append(diagnostic)
        }
    }

    /// Fast pre-filter: a matching line necessarily contains one of the
    /// severity words followed by a colon.
    private func containsSeverityMarker(_ line: ArraySlice<UInt8>) -> Bool {
        var index = line.startIndex
        while index < line.endIndex {
            for marker in Self.severityMarkers
            where line[index] == marker[0] && line[index...].starts(with: marker) {
                return true
            }
            index += 1
        }
        return false
    }
}

extension LogParser {
    /// Parses a complete log held in memory. For large inputs, prefer
    /// feeding chunks to a `LogParser` instance instead.
    public static func diagnostics(in log: String) -> [Diagnostic] {
        var parser = LogParser()
        parser.consume(log)
        return parser.finalize()
    }
}
