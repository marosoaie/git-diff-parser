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

        /// The same with `--binary`, so git can apply binary files too.
        var withBinaryPatches: Variant {
            var variant = self
            if !diffOptions.contains("--binary") {
                variant.diffOptions.append("--binary")
            }
            return variant
        }
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
        Variant(gitOptions: ["-c", "diff.suppressBlankEmpty=true"], diffOptions: ["-M"]),
        Variant(diffOptions: ["--diff-algorithm=histogram", "-M"]),
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

    // Not a variant: git apply would need -p0 to read it.
    @Test("a diff without prefixes, as diff.noprefix writes it, reads as the same files as one with them")
    func noPrefix() throws {
        let files = try [[], ["-c", "diff.noprefix=true"]].map { gitOptions in
            try Self.withDiff(Variant(gitOptions: gitOptions, diffOptions: ["-M"])) { diff, _ in
                DiffSummary.files(in: try Array(Data(contentsOf: diff)))
            }
        }
        #expect(files[0].count > 20)
        Oracle.expectEqualEntries(files[1], files[0])
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

    @Test("the full model holds every event, the same for any chunking", arguments: variants)
    func fullModel(variant: Variant) throws {
        try Self.withDiff(variant) { diff, _ in
            let bytes = try Array(Data(contentsOf: diff))
            let model = Diff.of(bytes)
            #expect(model.files.count > 20)
            Oracle.expectEqualEntries(model.replayedEvents, EventRecorder.eventsWithoutDamage(in: bytes))
            [1, 5].forEach { chunkSize in
                let same = Diff.of(bytes, chunkSize: chunkSize) == model
                #expect(same, "chunk size \(chunkSize)")
            }
        }
    }

    @Test("the full model renders back to git's diff byte for byte, for any chunking", arguments: variants)
    func roundTrip(variant: Variant) throws {
        try Self.withDiff(variant) { diff, _ in
            let bytes = try Array(Data(contentsOf: diff))
            let model = Diff.of(bytes)
            #expect(model.damage.isEmpty)
            Oracle.expectEqualLines([UInt8](rendering: model), bytes)
            let chunked = [UInt8](rendering: Diff.of(bytes, chunkSize: 1))
            #expect(chunked == bytes)
        }
    }

    @Test(
        "git apply --check takes the rendering, and applying it to the old tree gives the new tree",
        arguments: variants
    )
    func renderingApplies(variant: Variant) throws {
        try Self.withDiff(variant.withBinaryPatches) { diff, repository in
            let bytes = try Array(Data(contentsOf: diff))
            let rendered = [UInt8](rendering: Diff(diff: bytes))
            #expect(rendered == bytes)
            let renderedURL = diff.deletingLastPathComponent().appendingPathComponent("rendered.diff")
            try Data(rendered).write(to: renderedURL)
            let tree = try GitApply.treeAfterApplying(renderedURL, to: "main~1", in: repository)
            let head = String(decoding: try FastImport.git(["rev-parse", "main^{tree}"], in: repository), as: UTF8.self)
            #expect(tree == head.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test(
        "git show, git log -p, and git format-patch output, commit text and all, render back byte for byte",
        arguments: [
            ["show", "--stat", "-p", "--binary", "main"],
            // The root commit creates every file of the base tree.
            ["log", "-p", "--binary", "main"],
            ["format-patch", "--stdout", "--binary", "--root", "main"],
        ]
    )
    func logRoundTrip(arguments: [String]) throws {
        try Self.withOutput(of: arguments) { output, _ in
            let bytes = try Array(Data(contentsOf: output))
            let model = Diff(diff: bytes)
            #expect(model.damage.isEmpty)
            #expect(model.files.count > 20)
            #expect(!model.preamble.isEmpty)
            Oracle.expectEqualLines([UInt8](rendering: model), bytes)
            #expect([UInt8](rendering: Diff.of(bytes, chunkSize: 3)) == bytes)
        }
    }

    @Test("the fixture exercises every line ending the round trip checks")
    func lineEndingCoverage() throws {
        let lines = try Self.variants.flatMap { variant in
            try Self.withDiff(variant) { diff, _ in
                Diff(diff: try Array(Data(contentsOf: diff))).files.flatMap(\.lines)
            }
        }
        let kinds: [(String, (DiffLine) -> Bool)] = [
            ("line with \\r", \.info.endsWithCarriageReturn),
            ("line without a newline, old side", { $0.hasNoNewlineAtEnd && $0.info.kind == .deletion }),
            ("line without a newline, new side", { $0.hasNoNewlineAtEnd && $0.info.kind == .addition }),
            ("empty context line", { $0.info.kind == .context && $0.content.isEmpty && !$0.info.hasNoMarker }),
            ("bare empty context line", \.info.hasNoMarker),
        ]
        let missing = kinds.filter { _, matches in !lines.contains(where: matches) }.map(\.0)
        #expect(missing.isEmpty, "no line in the fixture is a \(missing)")
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

    /// Builds the fixture repository, renders `variant` to a diff file, and
    /// hands both to `body`, removing them afterwards.
    private static func withDiff<Result>(_ variant: Variant, _ body: (URL, URL) throws -> Result) throws -> Result {
        try withOutput(of: variant.gitOptions + ["diff"] + variant.diffOptions + ["main~1", "main"], body)
    }

    /// Builds the fixture repository, writes what `git` prints there for
    /// `arguments` to a file, and hands both to `body`, removing them
    /// afterwards.
    private static func withOutput<Result>(
        of arguments: [String], _ body: (URL, URL) throws -> Result
    ) throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-oracle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repository.git", isDirectory: true)
        try FastImport.makeRepository(at: repository, commits: [base, head])
        let diff = directory.appendingPathComponent("fixture.diff")
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

// MARK: Fixture

extension GitApplyOracleTests {
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
        .file(path: text("crlf.txt"), content: text("one\r\ntwo\r\nthree\r\n")),
        .file(path: text("no-eol.txt"), content: text("first\nlast")),
        .file(path: text("blank lines.txt"), content: text("one\n\ntwo\n\nthree\n")),
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
        // CRLF content whose last line loses its newline, a last line that
        // gets one, and empty context lines.
        .file(path: text("crlf.txt"), content: text("one\r\nTWO\r\nthree")),
        .file(path: text("no-eol.txt"), content: text("first\nlast\nmore\n")),
        .file(path: text("blank lines.txt"), content: text("one\n\n2\n\nthree\n")),
    ]
}
