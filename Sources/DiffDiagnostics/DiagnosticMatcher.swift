import BuildLogKit
import Foundation
import GitDiffKit

/// A diagnostic that landed on a line the PR touched, with its path resolved
/// to the repo-relative form used by the diff (what code-review UIs expect).
public struct MatchedDiagnostic: Sendable, Equatable, Codable {
    /// Repo-relative path, as spelled on the diff's new side.
    public var path: String
    public var line: Int
    public var column: Int?
    public var severity: Diagnostic.Severity
    public var message: String
    /// The violated rule, when the log parser extracted one
    /// (see `Diagnostic.rule`).
    public var rule: String?

    public init(
        path: String,
        line: Int,
        column: Int? = nil,
        severity: Diagnostic.Severity,
        message: String,
        rule: String? = nil
    ) {
        self.path = path
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
        self.rule = rule
    }

    // The wire format keys the path as "file" — the vocabulary GitHub-style
    // annotation consumers expect.
    private enum CodingKeys: String, CodingKey {
        case path = "file"
        case line
        case column
        case severity
        case message
        case rule
    }
}

/// Filters diagnostics down to the ones that touch changed lines.
public enum DiagnosticMatcher {
    /// Returns the diagnostics that land on changed lines, with their paths
    /// rewritten to the diff's repo-relative form and the result sorted by
    /// path, line, column, and message.
    ///
    /// - Parameters:
    ///   - diagnostics: All diagnostics found in the log.
    ///   - changes: Added/modified lines from the PR diff.
    ///   - repoRoot: If set, this prefix is stripped from absolute log paths
    ///     before comparing (e.g. the CI checkout directory). Paths that
    ///     still don't match exactly fall back to suffix matching, so in
    ///     most setups you can omit it.
    ///   - tolerance: Also match diagnostics within this many lines of a
    ///     changed line. 0 (exact) is the right default for compiler
    ///     warnings; 1–2 can help for whole-declaration lints that anchor a
    ///     line or two away from the edit.
    /// - Returns: The matching diagnostics, repo-relative and sorted.
    public static func match(
        _ diagnostics: [Diagnostic],
        against changes: ChangedLines,
        repoRoot: String? = nil,
        tolerance: Int = 0
    ) -> [MatchedDiagnostic] {
        let normalizedRoot = repoRoot.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var resolved: [String: String?] = [:]

        func resolve(_ logPath: String) -> String? {
            if let cached = resolved[logPath] { return cached }
            let result = resolveUncached(logPath)
            resolved[logPath] = result
            return result
        }

        func resolveUncached(_ logPath: String) -> String? {
            var path = logPath
            if let root = normalizedRoot, path.hasPrefix(root) {
                path = String(path.dropFirst(root.count))
            }
            if changes.files[path] != nil { return path }
            // The log path is usually absolute while diff paths are
            // repo-relative: match on the longest diff path the log path
            // ends with (component-aligned, to avoid `Bar.swift` matching
            // `FooBar.swift`).
            return changes.files.keys
                .filter { path == $0 || path.hasSuffix("/" + $0) }
                .max { $0.count < $1.count }
        }

        return diagnostics.compactMap { diagnostic -> MatchedDiagnostic? in
            guard let path = resolve(diagnostic.path),
                  changes.contains(line: diagnostic.line, in: path, tolerance: tolerance)
            else { return nil }
            return MatchedDiagnostic(
                path: path,
                line: diagnostic.line,
                column: diagnostic.column,
                severity: diagnostic.severity,
                message: diagnostic.message,
                rule: diagnostic.rule
            )
        }
        .sorted {
            ($0.path, $0.line, $0.column ?? 0, $0.message)
                < ($1.path, $1.line, $1.column ?? 0, $1.message)
        }
    }
}
