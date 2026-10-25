/// Damage the parser found in its input and how it recovered.
///
/// Diffs are untrusted input, so the parser never throws or traps on
/// them: it repairs what it can locally (`.info`) and abandons a file it
/// can't make sense of (`.error`), then carries on with the next file.
/// Reports are events; the library itself never logs.
public struct DamageReport: Sendable, Equatable {
    /// What was wrong with the input.
    public enum Reason: Sendable, Equatable {
        /// A hunk ended before its declared counts were used up: a line
        /// that doesn't fit the remaining budgets, a `diff ` line, or the
        /// end of input. The line is read again as if outside the hunk.
        case hunkCutShort
        /// A hunk line had no ` `/`+`/`-` marker; it is taken as context
        /// whose content is the whole line. An empty line isn't reported:
        /// whitespace stripping turns a blank context line into one, and
        /// `git apply` accepts it.
        case missingLineMarker
        /// A `\ No newline at end of file` that doesn't follow a hunk line,
        /// such as a duplicate or one before a file's first hunk; dropped.
        /// Outside any file (before the first one), a `\ ` line is text,
        /// passed on as an unrecognized line.
        case misplacedNoNewlineMarker
        /// A header line whose value didn't parse (a mode that isn't octal,
        /// a similarity over 100, a malformed `index` line); the value is
        /// ignored and the rest of the header kept.
        case ignoredHeaderValue
        /// A `@@` line that isn't a valid hunk header; it is passed on as
        /// an unrecognized line.
        case malformedHunkHeader
        /// A hunk before any file header; its lines are counted so they
        /// can't be mistaken for headers, and dropped.
        case hunkWithoutFile
        /// A `GIT binary patch` block that ends before a complete part.
        case malformedBinaryPatch
        /// A header block over the parser's bounds (64 lines, 1 MiB, or a
        /// line over the line cap). The file is abandoned: no `beginFile`,
        /// and its lines are dropped until the next file starts (for a
        /// combined diff, up to the next `diff ` line).
        case headerTooLarge
        /// A combined diff against more than 64 parents. The file is
        /// abandoned, and everything up to the next `diff ` line dropped.
        case tooManyParents
    }

    /// How a report affects the output.
    public enum Severity: Sendable, Equatable, Comparable {
        /// A local recovery; the file is still delivered.
        case info
        /// The file was abandoned and is missing from the output.
        case error
    }

    /// What was wrong with the input.
    public var reason: Reason
    /// The 1-based number of the input line where the damage was found;
    /// one past the last line for damage found at the end of input.
    public var lineNumber: Int
    /// The file the damage belongs to, as far as its header was read; nil
    /// outside any file.
    public var file: FileHeader?

    /// Creates a report from its parts.
    public init(reason: Reason, lineNumber: Int, file: FileHeader?) {
        self.reason = reason
        self.lineNumber = lineNumber
        self.file = file
    }

    /// `.error` when the file was abandoned, `.info` for a local recovery.
    public var severity: Severity {
        switch reason {
        case .headerTooLarge, .tooManyParents: .error
        case .hunkCutShort, .missingLineMarker, .misplacedNoNewlineMarker, .ignoredHeaderValue,
             .malformedHunkHeader, .hunkWithoutFile, .malformedBinaryPatch: .info
        }
    }
}
