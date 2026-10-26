import Foundation

/// Oracles from git's own patch parser: what `git apply --summary` and
/// `git apply --numstat -z` print for a diff file.
///
/// Both print paths as raw bytes (`-z` turns quoting off for numstat, and
/// the summary never quotes), so results compare as bytes.
enum GitApply {
    /// One line of `git apply --numstat -z`.
    struct NumstatEntry: Equatable, CustomStringConvertible {
        /// Nil for a binary file, which git prints as `-`.
        var added: Int?
        var deleted: Int?
        /// The new path, or the old one for a deletion.
        var path: [UInt8]

        var description: String {
            let counts = [added, deleted].map { $0.map(String.init) ?? "-" }
            return "\(counts[0])\t\(counts[1])\t\(String(decoding: path, as: UTF8.self))"
        }
    }

    static func summary(forDiffAt url: URL) throws -> [UInt8] {
        Array(try output(of: ["--summary"], forDiffAt: url))
    }

    static func numstat(forDiffAt url: URL) throws -> [NumstatEntry] {
        let records = Array(try output(of: ["--numstat", "-z"], forDiffAt: url))
            .split(separator: 0, omittingEmptySubsequences: false)
            .dropLast()
        return try records.map { record in
            // Paths may hold tabs, so only the first two split.
            let fields = record.split(separator: UInt8(ascii: "\t"), maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                throw FixtureError("unexpected numstat record \(String(decoding: record, as: UTF8.self))")
            }
            func count(_ field: ArraySlice<UInt8>) -> Int? { Int(String(decoding: field, as: UTF8.self)) }
            return NumstatEntry(added: count(fields[0]), deleted: count(fields[1]), path: Array(fields[2]))
        }
    }

    /// Checks the diff at `url` with `git apply --check`, applies it to
    /// `revision`'s tree in a scratch index of the bare `repository`, and
    /// returns the ID of the tree that results; throws if git rejects it.
    static func treeAfterApplying(_ url: URL, to revision: String, in repository: URL) throws -> String {
        let index = url.deletingLastPathComponent().appendingPathComponent("apply-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        _ = try FastImport.git(["read-tree", revision], in: repository, environment: environment)
        _ = try FastImport.git(["apply", "--cached", "--check", url.path], in: repository, environment: environment)
        _ = try FastImport.git(["apply", "--cached", url.path], in: repository, environment: environment)
        let tree = try FastImport.git(["write-tree"], in: repository, environment: environment)
        return String(decoding: tree, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs `git apply` with `options` on the diff at `url`.
    static func output(of options: [String], forDiffAt url: URL) throws -> Data {
        // Inside a work tree, git apply ignores every path outside the
        // current subdirectory. Run next to the diff and stop git from
        // discovering an enclosing repository, wherever the diff lives.
        let directory = url.deletingLastPathComponent()
        return try Subprocess.output(
            of: ["git", "apply"] + options + [url.path],
            in: directory,
            environment: ["GIT_CEILING_DIRECTORIES": directory.deletingLastPathComponent().path]
        )
    }
}
