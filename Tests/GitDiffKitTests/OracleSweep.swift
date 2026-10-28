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

    /// `entries` from `git show --numstat`, with a binary file that is moved
    /// or copied unchanged counted as text, where `files` is what the diff
    /// says.
    ///
    /// Such a file has no content in the diff, so the text can't say whether
    /// it's binary: git reads the blob and prints `-`, where `git apply`,
    /// which reads only the text, prints 0 like GitDiffKit.
    static func entries(
        _ entries: [GitApply.NumstatEntry], asTextReads files: [DiffSummary.File]
    ) -> [GitApply.NumstatEntry] {
        zip(entries, files).map { entry, file in
            let unchanged: Bool = switch file.header.change {
            case .renamed(similarity: 100), .copied(similarity: 100): true
            default: false
            }
            guard unchanged, entry.added == nil, !file.header.isBinary else { return entry }
            return GitApply.NumstatEntry(added: 0, deleted: 0, path: entry.path)
        } + entries.dropFirst(files.count)
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
