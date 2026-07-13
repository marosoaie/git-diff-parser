/// A single compiler/linter diagnostic extracted from a build or lint log.
public struct Diagnostic: Sendable, Hashable, Codable {
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
    /// The rule or flag that produced the diagnostic, when the tool-specific
    /// parser could extract one: a SwiftLint rule identifier
    /// (`line_length`), a SwiftFormat rule name (`indent`), or a clang
    /// warning flag (`-Wunused-variable`). Nil for the generic parser.
    public var rule: String?

    public init(
        path: String,
        line: Int,
        column: Int? = nil,
        severity: Severity,
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
}
