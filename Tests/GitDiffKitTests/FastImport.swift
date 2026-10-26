import Foundation

/// Builds bare repositories with `git fast-import`, so a test tree can hold
/// any path bytes, including names a file system would reject or
/// normalize (non-UTF-8, newlines).
enum FastImport {
    /// One change in a commit.
    enum Command {
        case file(path: [UInt8], content: [UInt8], mode: String = "100644")
        /// A submodule entry pointing at `commit`, which needn't exist.
        case gitlink(path: [UInt8], commit: String)
        case delete(path: [UInt8])
    }

    /// Git with the user's and the system's configuration shut out, so
    /// settings like `diff.noprefix` or `color.diff` can't change output;
    /// `environment` adds to it.
    static func git(_ arguments: [String], in repository: URL, environment: [String: String] = [:]) throws -> Data {
        try Subprocess.output(
            of: ["git", "-C", repository.path] + arguments,
            environment: isolatedEnvironment.merging(environment) { $1 }
        )
    }

    private static let isolatedEnvironment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    private static let newline = UInt8(ascii: "\n")

    /// Creates a bare SHA-1 repository at `url` whose `main` branch has one
    /// commit per element of `commits`, oldest first.
    static func makeRepository(at url: URL, commits: [[Command]]) throws {
        // SHA-1 whatever init.defaultObjectFormat or GIT_DEFAULT_HASH say:
        // gitlinks name 40-digit commits.
        _ = try Subprocess.output(
            of: ["git", "init", "--quiet", "--bare", "--object-format=sha1", url.path],
            environment: isolatedEnvironment
        )
        let stream = url.appendingPathComponent("fast-import.stream")
        try Data(self.stream(commits)).write(to: stream)
        _ = try Subprocess.output(
            of: ["git", "-C", url.path, "fast-import", "--quiet"],
            environment: isolatedEnvironment,
            input: stream
        )
    }

    private static func stream(_ commits: [[Command]]) -> [UInt8] {
        commits.enumerated().flatMap { time, commands in
            Array("""
                commit refs/heads/main
                committer Test <test@example.com> \(time) +0000
                data 0

                """.utf8) + commands.flatMap(line) + [newline]
        }
    }

    // Parts in a typed list, not a `+` chain: Swift 6.2 took seconds to
    // type-check the chain, close to its give-up limit.
    private static func line(_ command: Command) -> [UInt8] {
        let parts: [[UInt8]] = switch command {
        case let .file(path, content, mode):
            [Array("M \(mode) inline ".utf8), quoted(path), Array("\ndata \(content.count)\n".utf8), content]
        case let .gitlink(path, commit):
            [Array("M 160000 \(commit) ".utf8), quoted(path)]
        case let .delete(path):
            [Array("D ".utf8), quoted(path)]
        }
        return parts.flatMap(\.self) + [newline]
    }

    /// fast-import's C-style quoting, which takes every byte but these
    /// three as is.
    private static func quoted(_ path: [UInt8]) -> [UInt8] {
        let escaped = path.flatMap { byte -> [UInt8] in
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"): [UInt8(ascii: "\\"), byte]
            case newline: Array("\\n".utf8)
            default: [byte]
            }
        }
        return [UInt8(ascii: "\"")] + escaped + [UInt8(ascii: "\"")]
    }
}
