import Foundation

/// Parses SonarQube issue reports as returned by the Web API
/// (`GET /api/issues/search`) — either the raw response object or a merged
/// top-level array of issues (e.g. pages combined with `jq`).
///
/// Unlike the line-oriented parsers, the input is one JSON document, so
/// chunks are buffered and decoded on `finalize()`; reports are small
/// compared to build logs. Unmatchable issues are skipped: file-level
/// findings without a line number, and issues carrying a `resolution`
/// (fetch with `resolved=false` to avoid downloading those at all).
///
/// Issue paths come from `component` (`projectKey:relative/path`); project
/// keys may contain `:` but never `/`, so the path is taken after the last
/// `:`. Paths are relative to `sonar.projectBaseDir` — when that is not the
/// repository root, the matcher's suffix matching usually still resolves
/// them.
public struct SonarReportParser: LogParsing, Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        buffer.append(contentsOf: chunk)
    }

    public mutating func finalize() -> [Diagnostic] {
        defer { buffer.removeAll(keepingCapacity: false) }
        let data = Data(buffer)
        let decoder = JSONDecoder()
        // Malformed input yields no diagnostics rather than an error, like
        // the line-oriented parsers ignoring unrecognized lines.
        let issues = (try? decoder.decode(Response.self, from: data).issues)
            ?? (try? decoder.decode([Issue].self, from: data))
            ?? []
        var seen = Set<Diagnostic>()
        return issues
            .compactMap(\.diagnostic)
            .filter { seen.insert($0).inserted }
    }

    private struct Response: Decodable {
        var issues: [Issue]
    }

    private struct TextRange: Decodable {
        var startLine: Int?
        var startOffset: Int?
    }

    private struct Impact: Decodable {
        var severity: String?
    }

    private struct Issue: Decodable {
        var rule: String?
        var severity: String?
        var component: String
        var line: Int?
        var message: String?
        var resolution: String?
        var textRange: TextRange?
        var impacts: [Impact]?

        var diagnostic: Diagnostic? {
            guard resolution == nil, let line = line ?? textRange?.startLine else { return nil }
            let path = component.split(separator: ":").last.map(String.init) ?? component
            return Diagnostic(
                path: path,
                line: line,
                column: textRange?.startOffset.map { $0 + 1 },
                severity: mappedSeverity,
                message: message ?? rule ?? "SonarQube issue",
                rule: rule
            )
        }

        private var mappedSeverity: Diagnostic.Severity {
            // Legacy taxonomy first; newer servers may send only `impacts`
            // (the 10.x+ scale).
            switch severity ?? "" {
            case "BLOCKER", "CRITICAL": return .error
            case "MAJOR", "MINOR": return .warning
            case "INFO": return .note
            default: break
            }
            let impactSeverities = impacts?.compactMap(\.severity) ?? []
            if impactSeverities.contains(where: { $0 == "BLOCKER" || $0 == "HIGH" }) { return .error }
            if impactSeverities.contains(where: { $0 == "MEDIUM" || $0 == "LOW" }) { return .warning }
            return .note
        }
    }
}
