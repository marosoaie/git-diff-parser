import Foundation
import Testing
@testable import GitDiffKit

/// Real `diff -ruN` output, checked against `git apply`'s reading of it.
@Suite("Plain diff -ruN")
struct PlainDiffTests {
    private static let isGNUDiff = (try? Subprocess.output(of: ["diff", "--version"]))
        .map { String(decoding: $0, as: UTF8.self).contains("GNU diffutils") } ?? false

    /// Diffs two trees with `diff -ruN` in time zone `zone`, writes the
    /// result next to them, and hands its URL to `body`.
    private static func withDiff<Result>(zone: String, _ body: (URL) throws -> Result) throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-plain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [
            "old/mod.txt": "a\nb\n", "new/mod.txt": "a\nB\nc\n",
            "old/same.txt": "same\n", "new/same.txt": "same\n",
            "old/gone.txt": "gone\nfor\ngood\n",
            "new/sub/added.txt": "new\nfile\n",
        ]
        try files.forEach { path, content in
            let url = directory.appendingPathComponent(path)
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        // diff exits 1 when the trees differ.
        let diff = try Subprocess.output(
            of: ["sh", "-c", "diff -ruN old new; test $? -eq 1"],
            in: directory,
            environment: ["TZ": zone, "LC_ALL": "C"]
        )
        let url = directory.appendingPathComponent("plain.diff")
        try diff.write(to: url)
        return try body(url)
    }

    /// The files of the diff at `url`, with the leading `old/`/`new/` cut
    /// from their paths as `git apply -p1` does: the parser strips only
    /// git's `a/` and `b/`.
    private static func files(inDiffAt url: URL) throws -> [FileTally.File] {
        let strip = { (path: DiffPath?) in
            path.map { path in DiffPath(Array(path.bytes.drop { $0 != UInt8(ascii: "/") }.dropFirst())) }
        }
        return FileTally.files(in: Array(try Data(contentsOf: url))).map { file in
            var file = file
            file.header.oldPath = strip(file.header.oldPath)
            file.header.newPath = strip(file.header.newPath)
            return file
        }
    }

    @Test(
        "GNU diff's epoch timestamps make additions and deletions, as git apply --summary reads them",
        .enabled(if: isGNUDiff, "needs GNU diff, which writes the zone git looks for"),
        arguments: ["UTC0", "TST+8", "TST-5:30"]
    )
    func gnuDiffMatchesGitApply(zone: String) throws {
        try Self.withDiff(zone: zone) { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains(zone == "TST+8" ? "\t1969-12-31 16:00:00" : "\t1970-01-01 0"))
            let files = try Self.files(inDiffAt: url)
            #expect(files.map(\.header.change) == [.deleted, .modified, .added])
            let summary = try GitApply.summary(forDiffAt: url)
            #expect(String(decoding: summary, as: UTF8.self) == " delete gone.txt\n create sub/added.txt\n")
            Oracle.expectEqualLines(GitApply.summary(of: files), summary)
            Oracle.expectEqualEntries(GitApply.numstat(of: files), try GitApply.numstat(forDiffAt: url))
            #expect(ChangedLines(diff: text).lineSets == ["new/mod.txt": [2, 3], "new/sub/added.txt": [1, 2]])
        }
    }

    // Apple's diff writes local time with neither fraction nor zone, which
    // git's epoch check rejects too: it marks the files created or deleted
    // only because their state stays unknown, which a parser that delivers
    // the header before the hunks can't copy. Line counts agree regardless.
    @Test(
        "Apple diff's zoneless timestamps aren't the epoch, and line counts match git apply --numstat",
        .enabled(if: !isGNUDiff)
    )
    func appleDiff() throws {
        try Self.withDiff(zone: "UTC0") { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("\t1970-01-01 00:00:00\n"))
            let files = try Self.files(inDiffAt: url)
            #expect(files.map(\.header.change) == [.modified, .modified, .modified])
            Oracle.expectEqualEntries(GitApply.numstat(of: files), try GitApply.numstat(forDiffAt: url))
            #expect(ChangedLines(diff: text).lineSets == ["new/mod.txt": [2, 3], "new/sub/added.txt": [1, 2]])
        }
    }
}
