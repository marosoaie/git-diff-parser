import ArgumentParser
import Foundation
import GitDiffKit

struct Filter: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep only the log diagnostics that land on lines the diff touches.",
        discussion: """
            The log is scanned for clang-style diagnostics \
            ("path:line:col: warning: message"), the format emitted by swiftc, \
            xcodebuild, SwiftLint, and clang-tidy; all other log lines are \
            ignored. Absolute log paths are matched to repo-relative diff paths \
            by longest component-aligned suffix, so a --repo-root is rarely \
            needed.

            Example:
              git-diff-parser filter build.log --diff pr.diff --format github
            """
    )

    enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
        case json
        case github
        case text
    }

    @Argument(help: "Path to a build or lint log, or '-' for stdin.")
    var logPath: String

    @Option(help: "Path to the unified diff to filter against, or '-' for stdin.")
    var diff: String

    @Option(help: "Output format: structured (json), GitHub workflow annotation commands (github), or clang-style lines (text).")
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
        var logParser = LogParser()
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
            for diagnostic in matched {
                print(githubAnnotation(for: diagnostic))
            }
        case .text:
            for diagnostic in matched {
                let column = diagnostic.column.map { ":\($0)" } ?? ""
                print("\(diagnostic.path):\(diagnostic.line)\(column): \(diagnostic.severity.rawValue): \(diagnostic.message)")
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
        return "::\(command) \(properties)::\(escapeMessage(diagnostic.message))"
    }
}

extension Diagnostic.Severity: ExpressibleByArgument {}
