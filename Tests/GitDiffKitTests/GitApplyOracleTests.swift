import Foundation
import Testing
@testable import GitDiffKit

/// Cross-checks parsed headers against git's own reading of diffs that git
/// generated: `git apply --summary` and `--numstat -z` for what changed,
/// and `git ls-tree` for every path, mode, and object ID.
///
/// The repository comes from `git fast-import`, so it can hold names no
/// work tree could (non-UTF-8 bytes, newlines), and each variant renders
/// the same two commits with different `git diff` options.
@Suite("git apply oracle", .timeLimit(.minutes(2)))
struct GitApplyOracleTests {
    /// One way of rendering the fixture's two commits.
    struct Variant: CustomTestStringConvertible, Sendable {
        var gitOptions: [String] = []
        var diffOptions: [String]

        var testDescription: String { (["git"] + gitOptions + ["diff"] + diffOptions).joined(separator: " ") }
    }

    static let variants = [
        Variant(diffOptions: ["-M"]),
        Variant(diffOptions: ["-M", "-C", "--find-copies-harder"]),
        Variant(diffOptions: ["--binary", "-M"]),
        Variant(diffOptions: ["-B", "--no-renames"]),
        Variant(diffOptions: ["--no-renames"]),
        Variant(diffOptions: ["--full-index", "-M"]),
        Variant(gitOptions: ["-c", "core.quotePath=false"], diffOptions: ["-M"]),
        Variant(diffOptions: ["--src-prefix=i/", "--dst-prefix=w/", "-M"]),
    ]

    @Test("headers and line counts match git apply --summary and --numstat -z", arguments: variants)
    func matchesGitApply(variant: Variant) throws {
        try Self.withDiff(variant) { diff, _ in
            let files = DiffSummary.files(in: try Array(Data(contentsOf: diff)))
            Oracle.expectEqualLines(GitApply.summary(of: files), try GitApply.summary(forDiffAt: diff))
            Oracle.expectEqualEntries(GitApply.numstat(of: files), try GitApply.numstat(forDiffAt: diff))
        }
    }

    @Test("every path, mode, and object ID a header names is the one in git's trees", arguments: variants)
    func matchesTrees(variant: Variant) throws {
        try Self.withDiff(variant) { diff, repository in
            let base = try Self.tree("main~1", in: repository)
            let head = try Self.tree("main", in: repository)
            let headers = DiffSummary.files(in: try Array(Data(contentsOf: diff))).map(\.header)
            #expect(headers.count > 20)
            headers.forEach { header in
                Self.expect(
                    header, side: "old", path: header.oldPath, mode: header.oldMode, id: header.oldObjectID,
                    in: base, isMissing: header.change == .added
                )
                Self.expect(
                    header, side: "new", path: header.newPath, mode: header.newMode, id: header.newObjectID,
                    in: head, isMissing: header.change == .deleted
                )
            }
        }
    }

    @Test("--full-index writes 40-digit IDs, all zeros on the missing side")
    func fullIndex() throws {
        try Self.withDiff(Variant(diffOptions: ["--full-index", "-M"])) { diff, _ in
            let headers = DiffSummary.files(in: try Array(Data(contentsOf: diff))).map(\.header)
            let ids = headers.flatMap { [$0.oldObjectID, $0.newObjectID].compactMap(\.self) }
            #expect(ids.count > 20)
            #expect(ids.allSatisfy { $0.hexDigitCount == 40 })
            #expect(headers.filter { $0.change == .added }.allSatisfy { $0.oldObjectID?.isZero == true })
            #expect(headers.filter { $0.change == .deleted }.allSatisfy { $0.newObjectID?.isZero == true })
            #expect(headers.filter { $0.oldObjectID?.isZero == true }.allSatisfy { $0.change == .added })
        }
    }

    @Test("the fixture exercises every kind of header the oracles check")
    func coverage() throws {
        let headers = try [["-M", "-C", "--find-copies-harder"], ["-B", "--no-renames"]].flatMap { options in
            try Self.withDiff(Variant(diffOptions: options)) { diff, repository in
                let format = try FastImport.git(["rev-parse", "--show-object-format"], in: repository)
                #expect(String(decoding: format, as: UTF8.self) == "sha1\n")
                return DiffSummary.files(in: try Array(Data(contentsOf: diff))).map(\.header)
            }
        }
        let kinds: [(String, (FileHeader) -> Bool)] = [
            ("creation", { $0.change == .added }),
            ("deletion", { $0.change == .deleted }),
            ("modification", { $0.change == .modified }),
            ("rename with edits", {
                if case .renamed(let similarity) = $0.change { similarity ?? 100 < 100 } else { false }
            }),
            ("copy", { if case .copied = $0.change { true } else { false } }),
            ("rewrite", { $0.dissimilarity != nil }),
            ("mode change", \.modeChanged),
            ("binary file", \.isBinary),
            ("symlink", { $0.newMode == .symlink }),
            ("gitlink", { $0.newMode == .gitlink }),
            ("path that isn't UTF-8", { $0.newPath.map { !$0.string.utf8.elementsEqual($0.bytes) } ?? false }),
        ]
        let missing = kinds.filter { _, matches in !headers.contains(where: matches) }.map(\.0)
        #expect(missing.isEmpty, "no file in the fixture is a \(missing)")
    }

    @Test("scanning in small chunks gives the same files as scanning whole", arguments: variants)
    func chunkInvariance(variant: Variant) throws {
        try Self.withDiff(variant) { diff, _ in
            let bytes = try Array(Data(contentsOf: diff))
            let whole = DiffSummary.files(in: bytes)
            [1, 2, 5, 13].forEach { chunkSize in
                #expect(DiffSummary.files(in: bytes, chunkSize: chunkSize) == whole, "chunk size \(chunkSize)")
            }
        }
    }

    // MARK: Fixture

    private static func text(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    /// Ten lines naming `word`, with line `shouted` in capitals.
    private static func lines(_ word: String, shouting shouted: Int = 0) -> String {
        (1...10).map { "\($0 == shouted ? "LINE" : "line") \($0) of the \(word) file\n" }.joined()
    }

    /// Twenty lines that share no bytes with `digits`, so `-B` breaks the
    /// pair as a rewrite.
    private static let letters = (0..<20)
        .map { String(repeating: String(UnicodeScalar(97 + $0)), count: 30) + "\n" }
        .joined()
    private static let digits = (0..<20).map { String(repeating: "\($0 / 10)\($0 % 10)", count: 15) + "\n" }.joined()
    private static let latin1X = text("caf") + [0xE9] + text(" x.txt")
    private static let latin1Y = text("caf") + [0xE9] + text(" y.txt")

    private static let base: [FastImport.Command] = [
        .file(path: text("keep.txt"), content: text("one\ntwo\nthree\nfour\n")),
        .file(path: text("gone.txt"), content: text("bye\n")),
        .file(path: text("mode.sh"), content: text("echo\n")),
        .file(path: text("script.sh"), content: text("echo one\n")),
        .file(path: text("sp ace/old name.txt"), content: text(lines("renamed"))),
        .file(path: text("dir/sub/moved.txt"), content: text(lines("moved"))),
        .file(path: text("source.txt"), content: text(lines("copied"))),
        .file(path: text("rewrite.txt"), content: text(letters)),
        .file(path: text("rewrite.sh"), content: text(letters)),
        .file(path: text("link"), content: text("target\n")),
        .file(path: latin1X, content: text("latin\n")),
        .file(path: text("back\\slash.txt"), content: text("a\n")),
        .file(path: text("café.txt"), content: text("utf\n")),
        .file(path: text("b/nested.txt"), content: text("b\n")),
        .file(path: text("c/inner.txt"), content: text("c\n")),
        .file(path: text("sp ace/bin file.bin"), content: [0, 1, 2]),
        .file(path: text("old.bin"), content: [0] + text("old")),
        .file(path: text("sp ace/run me.sh"), content: text("run\n")),
        .file(path: text("empty-gone.txt"), content: []),
        .file(path: text("sp ace/gone file.txt"), content: text("x\n")),
    ]

    private static let head: [FastImport.Command] = [
        .file(path: text("keep.txt"), content: text("one\n2\nthree\nfour\n")),
        .delete(path: text("gone.txt")),
        .file(path: text("added.txt"), content: text("new\nfile\n")),
        .file(path: text("mode.sh"), content: text("echo\n"), mode: "100755"),
        .file(path: text("script.sh"), content: text("echo two\n"), mode: "100755"),
        .delete(path: text("sp ace/old name.txt")),
        .file(path: text("sp ace/new name.txt"), content: text(lines("renamed"))),
        .delete(path: text("dir/sub/moved.txt")),
        .file(path: text("dir/other/moved.txt"), content: text(lines("moved", shouting: 5))),
        .file(path: text("copy.txt"), content: text(lines("copied", shouting: 3))),
        .file(path: text("rewrite.txt"), content: text(digits)),
        .file(path: text("rewrite.sh"), content: text(digits), mode: "100755"),
        .file(path: text("link"), content: text("elsewhere"), mode: "120000"),
        .file(path: text("newlink"), content: text("keep.txt"), mode: "120000"),
        .gitlink(path: text("sub"), commit: "0123456789abcdef0123456789abcdef01234567"),
        .delete(path: latin1X),
        .file(path: latin1Y, content: text("latin\n")),
        .file(path: text("tab\there.txt"), content: text("t\n")),
        .file(path: text("quo\"te.txt"), content: text("q\n")),
        .file(path: text("back\\slash.txt"), content: text("b\n")),
        .file(path: text("new\nline.txt"), content: text("n\n")),
        .file(path: text("café.txt"), content: text("utf8\n")),
        .file(path: text("b/nested.txt"), content: text("bb\n")),
        .file(path: text("c/inner.txt"), content: text("cc\n")),
        .file(path: text("sp ace/bin file.bin"), content: [0, 1, 3]),
        .file(path: text("image.bin"), content: [0, 1, 2, 3] + text("png")),
        .delete(path: text("old.bin")),
        .file(path: text("sp ace/run me.sh"), content: text("run\n"), mode: "100755"),
        .file(path: text("empty.txt"), content: []),
        .file(path: text("sp ace/empty new.txt"), content: []),
        .delete(path: text("empty-gone.txt")),
        .file(path: text("sp ace/added file.txt"), content: text("spaced\n")),
        .delete(path: text("sp ace/gone file.txt")),
    ]

    /// Builds the fixture repository, renders `variant` to a diff file, and
    /// hands both to `body`, removing them afterwards.
    private static func withDiff<Result>(_ variant: Variant, _ body: (URL, URL) throws -> Result) throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-oracle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repository.git", isDirectory: true)
        try FastImport.makeRepository(at: repository, commits: [base, head])
        let diff = directory.appendingPathComponent("fixture.diff")
        let arguments = variant.gitOptions + ["diff"] + variant.diffOptions + ["main~1", "main"]
        try FastImport.git(arguments, in: repository).write(to: diff)
        return try body(diff, repository)
    }

    // MARK: Trees

    private struct TreeEntry {
        var mode: FileMode?
        var id: String
    }

    /// `git ls-tree -r -z`: `<mode> <type> <id>\t<path>\0` per entry.
    private static func tree(_ revision: String, in repository: URL) throws -> [[UInt8]: TreeEntry] {
        let output = Array(try FastImport.git(["ls-tree", "-r", "-z", revision], in: repository))
        let records = output.split(separator: 0)
        return try Dictionary(uniqueKeysWithValues: records.map { record in
            let fields = record.split(separator: UInt8(ascii: "\t"), maxSplits: 1, omittingEmptySubsequences: false)
            let meta = fields[0].split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
            guard fields.count == 2, meta.count == 3 else {
                throw FixtureError("unexpected ls-tree record \(String(decoding: record, as: UTF8.self))")
            }
            let entry = TreeEntry(mode: FileMode(octal: meta[0]), id: String(decoding: meta[2], as: UTF8.self))
            return (Array(fields[1]), entry)
        })
    }

    // Parameters spell out one side's fields, so the old and new sides
    // share the check.
    // swiftlint:disable:next function_parameter_count
    private static func expect(
        _ header: FileHeader,
        side: String,
        path: DiffPath?,
        mode: FileMode?,
        id: ObjectID?,
        in tree: [[UInt8]: TreeEntry],
        isMissing: Bool
    ) {
        let context = "\(side) side of \(header)"
        guard !isMissing else {
            #expect(path == nil && mode == nil, "\(context)")
            #expect(id.map(\.isZero) ?? true, "\(context)")
            return
        }
        guard let path, let entry = tree[path.bytes] else {
            Issue.record("\(context): the path isn't in the tree")
            return
        }
        #expect(mode.map { $0 == entry.mode } ?? true, "\(context): tree mode \(String(describing: entry.mode))")
        #expect(id.map { entry.id.hasPrefix($0.description) } ?? true, "\(context): tree ID \(entry.id)")
    }
}
