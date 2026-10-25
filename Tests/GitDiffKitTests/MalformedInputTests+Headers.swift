import Foundation
import Testing
@testable import GitDiffKit

/// Hostile extended headers: values that don't parse degrade one field, as
/// `git apply` reads them where it accepts them at all, and never trap.
extension MalformedInputTests {
    static func headers(_ diff: String) -> [FileHeader] {
        FileTally.files(in: Array(diff.utf8)).map(\.header)
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

        let files = FileTally.files(in: Array(diff.utf8))
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
}
