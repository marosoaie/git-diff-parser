import Foundation
import Testing
@testable import GitDiffKit

/// Combined diffs of real merges, built with git: recognized and skipped
/// (D9), so a merge's hunks never leak lines, headers, or damage.
@Suite("Combined diffs")
struct CombinedDiffTests {
    private typealias Event = EventRecorder.Event

    /// A work tree with git's configuration shut out and fixed identities
    /// and dates, so commits order the same on every run.
    private struct Repository {
        let url: URL
        private var clock = 1_700_000_000

        init(at url: URL) throws {
            self.url = url
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try Subprocess.output(
                of: ["git", "init", "--quiet", "--initial-branch=main", url.path],
                environment: Self.environment(date: 0)
            )
        }

        private static func environment(date: Int) -> [String: String] {
            [
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
                "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
                "GIT_AUTHOR_DATE": "@\(date) +0000", "GIT_COMMITTER_DATE": "@\(date) +0000",
            ]
        }

        /// Runs git in the work tree, each call a second later than the last.
        @discardableResult
        mutating func git(_ arguments: [String]) throws -> [UInt8] {
            clock += 1
            return Array(try Subprocess.output(
                of: ["git", "-C", url.path] + arguments,
                environment: Self.environment(date: clock)
            ))
        }

        func write(_ path: String, _ content: String) throws {
            try Data(content.utf8).write(to: url.appendingPathComponent(path))
        }

        mutating func commit(_ files: [String: String], message: String) throws {
            try files.forEach { try write($0.key, $0.value) }
            try git(["add", "--all"])
            try git(["commit", "--quiet", "--message", message])
        }
    }

    /// A repository whose `main` ends in a two-parent merge that resolves a
    /// conflict with a line of its own — `+ resolved`, which a combined
    /// diff prints as `+++ resolved` — and an octopus merge of three.
    private static func withMerges<Result>(_ body: (inout Repository) throws -> Result) throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-combined-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var repository = try Repository(at: directory)
        try repository.commit(["merged.txt": "a\nb\nc\n", "oct.txt": "1\n2\n3\n4\n5\n"], message: "base")
        try repository.git(["branch", "side"])
        try repository.git(["branch", "o1"])
        try repository.git(["branch", "o2"])
        try repository.commit(["merged.txt": "a\nB-main\nc\n"], message: "main")
        try repository.git(["checkout", "--quiet", "side"])
        try repository.commit(["merged.txt": "a\nB-side\nc\n"], message: "side")
        try repository.git(["checkout", "--quiet", "main"])
        // The merge conflicts; git exits nonzero and leaves markers behind.
        _ = try? repository.git(["merge", "--quiet", "side"])
        try repository.commit(["merged.txt": "a\n+ resolved\n- gone\nc\n"], message: "merge")
        try repository.git(["checkout", "--quiet", "o1"])
        try repository.commit(["oct.txt": "one\n2\n3\n4\n5\n"], message: "o1")
        try repository.git(["checkout", "--quiet", "o2"])
        try repository.commit(["oct.txt": "1\n2\n3\n4\nfive\n"], message: "o2")
        try repository.git(["checkout", "--quiet", "main"])
        try repository.git(["merge", "--quiet", "--no-commit", "o1", "o2"])
        // An edit of the merge's own on a line no parent changed, so the
        // file differs from all three parents in the same hunk.
        try repository.commit(["oct.txt": "one\n2\nthree\n4\nfive\n"], message: "octopus")
        return try body(&repository)
    }

    /// The headers of the files that began, in order.
    private static func headers(in events: [Event]) -> [FileHeader] {
        events.compactMap { event in
            guard case let .beginFile(header, _) = event else { return nil }
            return header
        }
    }

    /// Whether `event` is one a skipped combined file must not produce.
    private static func leaks(_ event: Event) -> Bool {
        switch event {
        case .beginHunk, .line, .noNewlineAtEndOfFile, .binaryPatchLine, .damage: true
        case .beginFile, .endFile, .unrecognizedLine: false
        }
    }

    @Test(
        "a merge's combined diff is one beginFile and endFile per file, with nothing in between",
        arguments: [
            (options: ["--cc"], merge: "main~1", parents: 2, path: "merged.txt"),
            (options: ["-c"], merge: "main~1", parents: 2, path: "merged.txt"),
            (options: ["--cc"], merge: "main", parents: 3, path: "oct.txt"),
            (options: ["-c"], merge: "main", parents: 3, path: "oct.txt"),
        ]
    )
    func skipped(options: [String], merge: String, parents: Int, path: String) throws {
        try Self.withMerges { repository in
            let diff = try repository.git(["show", "--format="] + options + [merge])
            let text = String(decoding: diff, as: UTF8.self)
            #expect(text.contains(options == ["--cc"] ? "diff --cc \(path)" : "diff --combined \(path)"))
            #expect(text.contains("@@@"))
            let events = EventRecorder.events(in: diff)
            #expect(!events.contains(where: Self.leaks), "\(events)")
            let headers = Self.headers(in: events)
            #expect(headers.map(\.format) == [.combined(parents: parents)])
            #expect(headers.map(\.newPath) == [DiffPath(Array(path.utf8))])
            #expect(events.filter { $0 == .endFile }.count == 1)
            #expect(ChangedLines(diff: text).files.isEmpty)
        }
    }

    @Test("a combined line that reads as +++ is not taken for a header")
    func plusLineIsNotAHeader() throws {
        try Self.withMerges { repository in
            let diff = try repository.git(["show", "--format=", "--cc", "main~1"])
            #expect(String(decoding: diff, as: UTF8.self).contains("\n+++ resolved\n"))
            #expect(Self.headers(in: EventRecorder.events(in: diff)).count == 1)
        }
    }

    @Test("files after merges in one stream still parse in full")
    func nextFileAfterMerge() throws {
        try Self.withMerges { repository in
            // The octopus, the two-parent merge, then main's own commit, an
            // ordinary diff, with their commit headers in between.
            let diff = try repository.git(["show", "--cc", "main", "main~1", "main~2"])
            let events = EventRecorder.events(in: diff)
            #expect(EventRecorder.damage(in: events).isEmpty)
            let headers = Self.headers(in: events)
            #expect(headers.map(\.format) == [.combined(parents: 3), .combined(parents: 2), .git])
            #expect(Array(events.suffix(4)) == [
                .line(LineInfo(kind: .deletion, oldNumber: 2, newNumber: nil), content: Array("b".utf8)),
                .line(LineInfo(kind: .addition, oldNumber: nil, newNumber: 2), content: Array("B-main".utf8)),
                .line(LineInfo(kind: .context, oldNumber: 3, newNumber: 3), content: Array("c".utf8)),
                .endFile,
            ])
            #expect(ChangedLines(diff: String(decoding: diff, as: UTF8.self)).lineSets == ["merged.txt": [2]])
        }
    }
}
