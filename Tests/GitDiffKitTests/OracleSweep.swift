import Foundation
@testable import GitDiffKit

/// The opt-in sweep over local clones: which clones, which commits, and
/// git's reading of each commit, from `git show`.
enum OracleSweep {
    /// The clones `GIT_DIFF_PARSER_SWEEP_CLONES` lists, separated by colons,
    /// or nil when it is unset.
    static let clones: [String]? = ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SWEEP_CLONES"]
        .map { $0.split(separator: ":").map(String.init) }

    /// `GIT_DIFF_PARSER_SWEEP_MAX_COMMITS`: how many of each clone's newest
    /// commits to check, or nil for all of them.
    static let maximumCommitCount = ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SWEEP_MAX_COMMITS"]
        .flatMap { Int($0) }

    /// How many test cases split each clone's commits between them, so the
    /// clone's `git show` runs go in parallel.
    static let shards = Array(0..<max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// Merges show their changes against the first parent, and copies are
    /// found as well as renames, in both the patch and the numstat.
    static let showOptions = ["--diff-merges=first-parent", "--find-copies"]

    /// The commits reachable from the clone's `HEAD`, newest first.
    static func commits(in clone: String) throws -> [String] {
        let limit = maximumCommitCount.map { ["--max-count=\($0)"] } ?? []
        return String(decoding: try git(["rev-list"] + limit + ["HEAD"], in: clone), as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    /// What `git show` prints for `commit`: its header and message, then its
    /// diff.
    static func patch(of commit: String, in clone: String) throws -> [UInt8] {
        Array(try git(["show"] + showOptions + [commit], in: clone))
    }

    /// `git show --numstat -z` for `commit`: `added\tdeleted\tpath\0` per
    /// file, or, for a rename or copy, an empty path and then `old\0new\0`.
    static func numstat(of commit: String, in clone: String) throws -> [GitApply.NumstatEntry] {
        let output = Array(try git(["show", "--format=", "--numstat", "-z"] + showOptions + [commit], in: clone))
        var fields = output.split(separator: 0, omittingEmptySubsequences: false).makeIterator()
        var entries: [GitApply.NumstatEntry] = []
        // A cursor rather than a map: a rename's record takes three fields.
        while let record = fields.next(), !record.isEmpty {
            let columns = record.split(separator: UInt8(ascii: "\t"), maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else {
                throw FixtureError("unexpected numstat record \(String(decoding: record, as: UTF8.self)) in \(commit)")
            }
            var path = columns[2]
            if path.isEmpty {
                _ = fields.next()
                path = fields.next() ?? []
            }
            func count(_ column: ArraySlice<UInt8>) -> Int? { Int(String(decoding: column, as: UTF8.self)) }
            entries.append(
                GitApply.NumstatEntry(added: count(columns[0]), deleted: count(columns[1]), path: Array(path))
            )
        }
        return entries
    }

    /// GitDiffKit's counts for `files`, and git's `oracle` for them, made
    /// comparable where `git show --numstat` reads more than the text.
    ///
    /// Two differences are git's, not the text's, and `git apply --numstat`,
    /// which reads only the text, agrees with GitDiffKit on both:
    /// - A type change (a file replaced by a symlink, say) is two files in
    ///   the diff, a deletion and a creation of one path, where git show
    ///   prints one line for both. Ours are folded into one.
    /// - A file whose content didn't change (a pure rename or copy, or a
    ///   mode change) has no content in the diff, so the text can't say
    ///   whether it's binary, where git reads the blob and prints `-` for a
    ///   binary one. Git's are counted as text.
    static func comparable(
        _ files: [DiffSummary.File], _ oracle: [GitApply.NumstatEntry]
    ) -> (ours: [GitApply.NumstatEntry], oracle: [GitApply.NumstatEntry]) {
        let folded = zip(files.map(\.header), GitApply.numstat(of: files))
            .reduce(into: [(header: FileHeader, entry: GitApply.NumstatEntry)]()) { folded, next in
                guard let last = folded.last, case .deleted = last.header.change, case .added = next.0.change,
                      last.entry.path == next.1.path
                else {
                    folded.append(next)
                    return
                }
                let sum = { (one: Int?, other: Int?) in one.flatMap { one in other.map { one + $0 } } }
                folded[folded.count - 1].entry = GitApply.NumstatEntry(
                    added: sum(last.entry.added, next.1.added), deleted: sum(last.entry.deleted, next.1.deleted),
                    path: last.entry.path
                )
            }
        let oracle = zip(oracle, folded).map { entry, ours in
            guard ours.header.oldObjectID == ours.header.newObjectID, entry.added == nil, ours.entry.added == 0
            else { return entry }
            return GitApply.NumstatEntry(added: 0, deleted: 0, path: entry.path)
        } + oracle.dropFirst(folded.count)
        return (folded.map(\.entry), oracle)
    }

    /// Runs git in `clone` with no global or system configuration, so the
    /// output doesn't depend on whoever runs the sweep.
    private static func git(_ arguments: [String], in clone: String) throws -> Data {
        try Subprocess.output(
            of: ["git", "-C", clone] + arguments,
            environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        )
    }

    // MARK: What a clone holds

    /// The kinds of file and line the record counts, so it can say what the
    /// sweep exercised.
    static let fileKinds: [(String, @Sendable (DiffFile) -> Bool)] = [
        ("renames", { if case .renamed = $0.header.change { true } else { false } }),
        ("copies", { if case .copied = $0.header.change { true } else { false } }),
        ("mode changes", \.header.modeChanged),
        ("binaries", \.header.isBinary),
        ("symlinks", { $0.header.newMode == .symlink || $0.header.oldMode == .symlink }),
        ("submodules", { $0.header.newMode == .gitlink || $0.header.oldMode == .gitlink }),
        ("quoted paths", { $0.rawHeader.prefix { $0 != UInt8(ascii: "\n") }.contains(UInt8(ascii: "\"")) }),
        ("non-UTF-8 paths", { file in
            [file.header.oldPath, file.header.newPath].contains { path in
                path.map { String(validating: $0.bytes, as: UTF8.self) == nil } ?? false
            }
        }),
    ]

    static let lineKinds: [(String, @Sendable (DiffLine) -> Bool)] = [
        ("CRLF lines", \.info.endsWithCarriageReturn),
        ("no-newline lines", \.hasNoNewlineAtEnd),
        ("non-UTF-8 lines", { String(validating: $0.content, as: UTF8.self) == nil }),
    ]

    /// How many files and lines of `diff` are of each kind, by name.
    static func tally(_ diff: Diff) -> [String: Int] {
        let files = fileKinds.map { name, matches in (name, diff.files.count(where: matches)) }
        let lines = lineKinds.map { name, matches in
            (name, diff.files.reduce(0) { $0 + $1.lines.count(where: matches) })
        }
        return Dictionary(uniqueKeysWithValues: files + lines + [("files", diff.files.count)])
    }
}
