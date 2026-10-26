import Foundation
import Testing
@testable import GitDiffKit

/// Hostile extended headers: values that don't parse degrade one field, as
/// `git apply` reads them where it accepts them at all, and never trap.
extension MalformedInputTests {
    static func headers(_ diff: String) -> [FileHeader] {
        DiffSummary.files(in: Array(diff.utf8)).map(\.header)
    }

    static let damagedHeaders = [
        """
        diff --git a/old.txt b/new.txt
        similarity index 150%
        rename from old.txt
        rename to new.txt

        """,
        """
        diff --git a/old.txt b/new.txt
        similarity index 99999999999999999999999999999999%
        rename from old.txt
        rename to new.txt

        """,
        """
        diff --git a/x b/x
        index abc 100644
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -a
        +b

        """,
        """
        diff --git a/x b/x
        index zz..yy 100644
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -a
        +b

        """,
        """
        diff --git a/x b/x
        index \(String(repeating: "a", count: 65))..\(String(repeating: "b", count: 65))
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -a
        +b

        """,
        // A header cut off at the end of the input, without a newline. (git
        // rejects a mode line cut off that way, so the cut is in `index`.)
        """
        diff --git a/x b/x
        new file mode 100644
        index 0000000..e69de29
        """,
    ]

    @Test("damaged header values are read the way git apply reads them", arguments: damagedHeaders)
    func damagedHeadersMatchGitApply(diff: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-damaged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("damaged.diff")
        try Data(diff.utf8).write(to: url)

        let files = DiffSummary.files(in: Array(diff.utf8))
        Oracle.expectEqualLines(GitApply.summary(of: files), try GitApply.summary(forDiffAt: url))
        Oracle.expectEqualEntries(GitApply.numstat(of: files), try GitApply.numstat(forDiffAt: url))
    }

    @Test("values that don't parse are dropped one by one, without trapping")
    func unparsableHeaderValues() {
        let headers = Self.headers("""
            diff --git a/x b/x
            old mode 7777777777777777777777
            new mode 100755
            similarity index 150%
            dissimilarity index 99999999999999999999999%
            index \(String(repeating: "a", count: 65))..0123abc 1000000000000000000000

            """)
        #expect(headers.count == 1)
        #expect(headers.first?.oldMode == nil)
        #expect(headers.first?.newMode == .executable)
        #expect(headers.first?.dissimilarity == nil)
        #expect(headers.first?.oldObjectID == nil)
        #expect(headers.first?.newObjectID?.description == "0123abc")
        #expect(headers.first?.oldPath == DiffPath(Array("x".utf8)))
    }

    @Test("an index line without '..' names no object IDs")
    func indexWithoutDots() {
        let header = Self.headers("diff --git a/x b/x\nindex abc.def 100644\n").first
        #expect(header?.oldObjectID == nil && header?.newObjectID == nil && header?.oldMode == nil)
    }

    @Test(
        "broken quoting in a diff --git line leaves the path unknown instead of trapping",
        arguments: ["\"a/abc b/abc", "\"", "\"a/abc\\\" b/abc", "a/x \"b/x", "a/x \"b/x\\\"", ""]
    )
    func brokenQuoting(names: String) {
        #expect(FileHeaderParser.gitLinePath(Array(names.utf8)[...]) == nil)
        let headers = Self.headers("diff --git \(names)\nrename from \(names)\n")
        #expect(headers.count == 1)
    }

    @Test("a megabyte of spaces in a diff --git line splits in linear time")
    func hugeSpaceRun() {
        // Just inside the header bound of 1 MiB.
        let line = "diff --git " + String(repeating: " ", count: (1 << 20) - 64)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(Self.headers(line + "\nold mode 100644\n").count == 1)
        }
        #expect(elapsed < .seconds(1))
    }

    @Test("damage in one file's header leaves the next file's header intact")
    func damageStaysInOneFile() {
        let headers = Self.headers("""
            diff --git "a/broken b/broken
            old mode 99999999999999999999
            index zz..
            rename from "unterminated
            similarity index 1000%
            diff --git a/old.txt b/new.txt
            similarity index 90%
            rename from old.txt
            rename to new.txt
            index 1234567..89abcde 100644
            --- a/old.txt
            +++ b/new.txt
            @@ -1 +1 @@
            -a
            +b

            """)
        #expect(headers.count == 2)
        #expect(headers.last == FileHeader(
            format: .git,
            change: .renamed(similarity: 90),
            oldPath: DiffPath(Array("old.txt".utf8)),
            newPath: DiffPath(Array("new.txt".utf8)),
            oldMode: .regular,
            newMode: .regular,
            oldObjectID: ObjectID(hex: Array("1234567".utf8)[...]),
            newObjectID: ObjectID(hex: Array("89abcde".utf8)[...])
        ))
    }

    // Regression (D11, from 2.3's review): `diff -N` writes the Unix epoch
    // for the missing side of an added or deleted file, and git apply reads
    // that as a creation or deletion. It recognizes the epoch in any zone,
    // but only with the zone written out and zero seconds.
    @Test(
        "an epoch timestamp on one side makes a plain diff an addition or deletion, as git apply reads it",
        arguments: [
            (old: "1970-01-01 00:00:00.000000000 +0000", new: "2026-10-25 12:00:00.000000000 +0000", Change.added),
            (old: "2026-10-25 12:00:00 +0000", new: "1970-01-01 00:00:00 +0000", .deleted),
            (old: "1969-12-31 16:00:00 -0800", new: "2026-10-25 12:00:00 -0700", .added),
            (old: "1970-01-01 05:30:00.0 +05:30", new: "2026-10-25 12:00:00 +0530", .added),
            // Not the epoch: one second past, an hour off for its zone, a
            // fraction that isn't zero, and no zone (Apple's diff -N).
            (old: "1970-01-01 01:00:01 +0100", new: "2026-10-25 12:00:00 +0100", .modified),
            (old: "1970-01-01 01:00:00 +0000", new: "2026-10-25 12:00:00 +0000", .modified),
            (old: "1970-01-01 00:00:00.000000001 +0000", new: "2026-10-25 12:00:00 +0000", .modified),
            (old: "1970-01-01 01:00:00", new: "2026-10-25 12:00:00", .modified),
        ]
    )
    func epochTimestamps(old: String, new: String, change: Change) {
        let hunk = switch change {
        case .added: "@@ -0,0 +1 @@\n+y\n"
        case .deleted: "@@ -1 +0,0 @@\n-x\n"
        default: "@@ -1 +1 @@\n-x\n+y\n"
        }
        let diff = "--- a/file.txt\t\(old)\n+++ b/file.txt\t\(new)\n" + hunk
        let headers = Self.headers(diff)
        let path = DiffPath(Array("file.txt".utf8))
        #expect(headers.map(\.change) == [change])
        // As for /dev/null, the missing side has no path.
        #expect(headers.first?.oldPath == (change == .added ? nil : path))
        #expect(headers.first?.newPath == (change == .deleted ? nil : path))
        #expect(ChangedLines(diff: diff).lineSets == (change == .deleted ? [:] : ["file.txt": [1]]))
    }

    // Accepted divergence from 0.1: such a deletion recorded its added
    // lines; now it has no new path to record them under, like a git
    // diff's `deleted file mode` file.
    @Test("an epoch-deleted file that still adds lines records none, which git apply refuses anyway")
    func epochDeletionWithAdditions() {
        let diff = """
            --- a/file.txt\t2026-10-25 12:00:00 +0000
            +++ b/file.txt\t1970-01-01 00:00:00 +0000
            @@ -1 +1 @@
            -x
            +y

            """
        #expect(Self.headers(diff).map(\.change) == [.deleted])
        #expect(ChangedLines(diff: diff).files.isEmpty)
    }
}
