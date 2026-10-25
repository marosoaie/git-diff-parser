import Testing
@testable import GitDiffKit

@Suite("File headers")
struct FileHeaderParserTests {
    static func scan(_ diff: String) -> [FileHeaderScanner.File] {
        var scanner = FileHeaderScanner()
        scanner.consume(Array(diff.utf8)[...])
        return scanner.finalize()
    }

    static func path(_ text: String) -> DiffPath {
        DiffPath(Array(text.utf8))
    }

    @Test("a rename between quoted non-UTF-8 paths keeps the exact bytes")
    func quotedRename() {
        let files = Self.scan("""
            diff --git "a/caf\\351 x.txt" "b/caf\\351 y.txt"
            similarity index 100%
            rename from "caf\\351 x.txt"
            rename to "caf\\351 y.txt"

            """)
        #expect(files.map(\.header) == [FileHeader(
            format: .git,
            change: .renamed(similarity: 100),
            oldPath: DiffPath(Array("caf".utf8) + [0xE9] + Array(" x.txt".utf8)),
            newPath: DiffPath(Array("caf".utf8) + [0xE9] + Array(" y.txt".utf8))
        )])
    }

    @Test("a type change is a deletion followed by a creation of the same path")
    func typeChange() {
        let files = Self.scan("""
            diff --git a/link b/link
            deleted file mode 100644
            index eb5a316..0000000
            --- a/link
            +++ /dev/null
            @@ -1 +0,0 @@
            -target
            diff --git a/link b/link
            new file mode 120000
            index 0000000..f98eb10
            --- /dev/null
            +++ b/link
            @@ -0,0 +1 @@
            +elsewhere
            \\ No newline at end of file

            """)
        #expect(files.map(\.header.change) == [.deleted, .added])
        #expect(files.map(\.header.oldPath) == [Self.path("link"), nil])
        #expect(files.map(\.header.newPath) == [nil, Self.path("link")])
        #expect(files.map(\.header.oldMode) == [.regular, nil])
        #expect(files.map(\.header.newMode) == [nil, .symlink])
        #expect(files.map(\.header.oldObjectID?.description) == ["eb5a316", "0000000"])
        #expect(files.map { [$0.addedLines, $0.deletedLines] } == [[0, 1], [1, 0]])
    }

    @Test("a binary file and a mode change without ---/+++ take their path from the diff --git line")
    func pathFromGitLine() {
        let files = Self.scan("""
            diff --git a/mode.sh b/mode.sh
            old mode 100644
            new mode 100755
            diff --git a/sp ace/bin file.bin b/sp ace/bin file.bin
            index 8352675..1592e5c 100644
            Binary files a/sp ace/bin file.bin and b/sp ace/bin file.bin differ

            """)
        #expect(files.map(\.header) == [
            FileHeader(
                format: .git, change: .modified, oldPath: Self.path("mode.sh"), newPath: Self.path("mode.sh"),
                oldMode: .regular, newMode: .executable
            ),
            FileHeader(
                format: .git, change: .modified,
                oldPath: Self.path("sp ace/bin file.bin"), newPath: Self.path("sp ace/bin file.bin"),
                oldMode: .regular, newMode: .regular,
                oldObjectID: ObjectID(hex: Array("8352675".utf8)[...]),
                newObjectID: ObjectID(hex: Array("1592e5c".utf8)[...]),
                isBinary: true
            ),
        ])
        #expect(files.map(\.header.modeChanged) == [true, false])
    }
}
