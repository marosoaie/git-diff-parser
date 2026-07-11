import Foundation

/// Parses `xcodebuild` / `swiftc` / clang build output.
///
/// Same line recognition as `ClangStyleLogParser`, plus extraction of the
/// clang warning flag when the message carries one:
///
///     src/main.c:7:9: warning: unused variable 'x' [-Wunused-variable]
///
/// becomes message `unused variable 'x'` with rule `-Wunused-variable`.
/// `-Werror`-promoted diagnostics carry a comma-separated flag list
/// (`[-Werror,-Wunused-variable]`); the last element — the specific flag —
/// becomes the rule. (swiftc diagnostics have no flags; those pass through
/// with a nil rule.)
public struct XcodeLogParser: LogParsing {
    private var base: ClangStyleLogParser

    public init() {
        base = ClangStyleLogParser { diagnostic in
            var diagnostic = diagnostic
            // Flags can contain '#' (-W#warnings), '=' (GCC's -Wformat=),
            // etc. — accept anything up to the closing bracket rather than
            // enumerating characters.
            if let match = diagnostic.message.firstMatch(of: /\s*\[(?<flags>-W[^\]]+)\]$/) {
                diagnostic.rule = match.flags.split(separator: ",").last.map(String.init)
                diagnostic.message.removeSubrange(match.range)
            }
            return diagnostic
        }
    }

    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        base.consume(chunk)
    }

    public mutating func finalize() -> [Diagnostic] {
        base.finalize()
    }
}

/// Parses SwiftLint's default (Xcode-style) reporter output:
///
///     /path/File.swift:10:5: warning: Line Length Violation: … (line_length)
///
/// The trailing parenthesized rule identifier is extracted into
/// `Diagnostic.rule` and stripped from the message.
public struct SwiftLintLogParser: LogParsing {
    private var base: ClangStyleLogParser

    public init() {
        base = ClangStyleLogParser { diagnostic in
            var diagnostic = diagnostic
            // Built-in rule ids are snake_case, but custom rules
            // (custom_rules: in .swiftlint.yml) can be camelCase or
            // kebab-case; every violation line ends with the id, so the $
            // anchor alone bounds the match.
            if let match = diagnostic.message.firstMatch(of: /\s*\((?<rule>[A-Za-z][A-Za-z0-9_-]*)\)$/) {
                diagnostic.rule = String(match.rule)
                diagnostic.message.removeSubrange(match.range)
            }
            return diagnostic
        }
    }

    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        base.consume(chunk)
    }

    public mutating func finalize() -> [Diagnostic] {
        base.finalize()
    }
}

/// Parses `swiftformat --lint` output:
///
///     /path/File.swift:12:1: warning: (indent) Indent code in accordance …
///
/// The leading parenthesized rule name is extracted into `Diagnostic.rule`
/// and stripped from the message.
public struct SwiftFormatLogParser: LogParsing {
    private var base: ClangStyleLogParser

    public init() {
        base = ClangStyleLogParser { diagnostic in
            var diagnostic = diagnostic
            if let match = diagnostic.message.firstMatch(of: /^\((?<rule>[A-Za-z][A-Za-z0-9_]*)\)\s*/) {
                diagnostic.rule = String(match.rule)
                diagnostic.message.removeSubrange(match.range)
            }
            return diagnostic
        }
    }

    public mutating func consume(_ chunk: ArraySlice<UInt8>) {
        base.consume(chunk)
    }

    public mutating func finalize() -> [Diagnostic] {
        base.finalize()
    }
}
