import ArgumentParser
import BuildLogKit
import DiffDiagnostics
import Foundation
import GitDiffKit

struct Filter: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep only the log diagnostics that land on lines the diff touches.",
        discussion: """
            The log is scanned for clang-style diagnostics \
            ("path:line:col: warning: message"), the format emitted by swiftc, \
            xcodebuild, SwiftLint, and SwiftFormat; all other log lines are \
            ignored. Pick a --tool to additionally extract the violated rule \
            (SwiftLint rule identifier, SwiftFormat rule name, clang warning \
            flag) into the output. Absolute log paths are matched to \
            repo-relative diff paths by longest component-aligned suffix, so \
            a --repo-root is rarely needed.

            Example:
              git-diff-parser filter lint.log --diff pr.diff --tool swiftlint --format github
            """
    )

    enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
        case json
        case github
        case text
    }

    enum Tool: String, CaseIterable, ExpressibleByArgument {
        case generic
        case xcodebuild
        case swiftlint
        case swiftformat
        case sonar

        func makeParser() -> any LogParsing {
            switch self {
            case .generic: ClangStyleLogParser()
            case .xcodebuild: XcodeLogParser()
            case .swiftlint: SwiftLintLogParser()
            case .swiftformat: SwiftFormatLogParser()
            case .sonar: SonarReportParser()
            }
        }
    }

    @Argument(help: "Path to a build or lint log, or '-' for stdin.")
    var logPath: String

    @Option(help: "Path to the unified diff to filter against, or '-' for stdin.")
    var diff: String

    @Option(help: """
        The tool that produced the log. Tool-specific parsers also extract \
        the violated rule; generic handles any clang-style log, and sonar \
        reads a SonarQube /api/issues/search JSON report.
        """)
    var tool: Tool = .generic

    @Option(help: """
        Output format: structured (json), GitHub workflow annotation \
        commands (github), or clang-style lines (text).
        """)
    var format: OutputFormat = .json

    @Option(help: "Prefix to strip from absolute log paths before matching.")
    var repoRoot: String?

    @Option(help: "Also match diagnostics within this many lines of a change.")
    var tolerance: Int = 0

    @Option(help: "Exit with code 1 if any matched diagnostic is at or above this severity.")
    var failOn: Diagnostic.Severity?

    func validate() throws {
        guard tolerance >= 0 else {
            throw ValidationError("'--tolerance' must be a non-negative integer.")
        }
        guard !(diff == "-" && logPath == "-") else {
            throw ValidationError("Only one of the log and the diff can come from stdin.")
        }
    }

    func run() throws {
        let changes = try ChangedLines(streamingFrom: diff)
        var logParser = tool.makeParser()
        try forEachChunk(ofInput: logPath) { logParser.consume($0) }
        let matched = DiagnosticMatcher.match(
            logParser.finalize(),
            against: changes,
            repoRoot: repoRoot,
            tolerance: tolerance
        )

        switch format {
        case .json:
            print(try JSON.encode(matched))
        case .github:
            matched.forEach { print(githubAnnotation(for: $0)) }
        case .text:
            matched.forEach { diagnostic in
                let column = diagnostic.column.map { ":\($0)" } ?? ""
                let rule = diagnostic.rule.map { " (\($0))" } ?? ""
                print("""
                    \(diagnostic.path):\(diagnostic.line)\(column): \
                    \(diagnostic.severity.rawValue): \(diagnostic.message)\(rule)
                    """)
            }
        }

        if let failOn, matched.contains(where: { $0.severity >= failOn }) {
            throw ExitCode(1)
        }
    }

    /// Formats a diagnostic as a GitHub Actions workflow command; GitHub
    /// renders these as PR annotations with no further tooling.
    private func githubAnnotation(for diagnostic: MatchedDiagnostic) -> String {
        let command =
            switch diagnostic.severity {
            case .error: "error"
            case .warning: "warning"
            case .note: "notice"
            }
        // Escaping rules per
        // https://docs.github.com/actions/reference/workflow-commands-for-github-actions
        func escapeProperty(_ text: String) -> String {
            text.replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: "\r", with: "%0D")
                .replacingOccurrences(of: "\n", with: "%0A")
                .replacingOccurrences(of: ":", with: "%3A")
                .replacingOccurrences(of: ",", with: "%2C")
        }
        func escapeMessage(_ text: String) -> String {
            text.replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: "\r", with: "%0D")
                .replacingOccurrences(of: "\n", with: "%0A")
        }
        var properties = "file=\(escapeProperty(diagnostic.path)),line=\(diagnostic.line)"
        if let column = diagnostic.column {
            properties += ",col=\(column)"
        }
        if let rule = diagnostic.rule {
            properties += ",title=\(escapeProperty(rule))"
        }
        return "::\(command) \(properties)::\(escapeMessage(diagnostic.message))"
    }
}

extension Diagnostic.Severity: ExpressibleByArgument {}
