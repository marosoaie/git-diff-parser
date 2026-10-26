import Testing
@testable import GitDiffKit

@Suite("File headers")
struct FileHeaderParserTests {
    static func scan(_ diff: String) -> [DiffSummary.File] {
        DiffSummary.files(in: Array(diff.utf8))
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
        #expect(files.map { [$0.addedLineCount, $0.deletedLineCount] } == [[0, 1], [1, 0]])
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

    @Test(
        "object IDs take 1 to 64 hex digits in either case and print lowercase",
        arguments: [
            ("abc1234", "abc1234"),
            ("ABCDEF0", "abcdef0"),
            (String(repeating: "f", count: 40), String(repeating: "f", count: 40)),
            (String(repeating: "0123456789abcdef", count: 4), String(repeating: "0123456789abcdef", count: 4)),
        ]
    )
    func objectIDs(hex: String, description: String) {
        let id = ObjectID(hex: Array(hex.utf8)[...])
        #expect(id?.description == description)
        #expect(id?.hexDigitCount == hex.count)
        #expect(id?.isZero == false)
    }

    @Test("an object ID rejects no digits, too many, and non-hex bytes", arguments: [
        "", String(repeating: "a", count: 65), "abcg", "12 4", "-1",
    ])
    func invalidObjectIDs(hex: String) {
        #expect(ObjectID(hex: Array(hex.utf8)[...]) == nil)
    }

    @Test("an all-zero object ID of any length is git's missing object")
    func zeroObjectID() {
        #expect(ObjectID(hex: Array("0000000".utf8)[...])?.isZero == true)
        #expect(ObjectID(hex: Array(String(repeating: "0", count: 64).utf8)[...])?.isZero == true)
        #expect(ObjectID(hex: Array("0000001".utf8)[...]) != ObjectID(hex: Array("00000010".utf8)[...]))
    }

    @Test("git's original 'rename old'/'rename new' spellings and a rewrite's dissimilarity parse")
    func oldRenameSpellingsAndDissimilarity() {
        let headers = Self.scan("""
            diff --git a/one b/two
            similarity index 75%
            rename old one
            rename new two
            diff --git a/three b/three
            dissimilarity index 88%

            """).map(\.header)
        #expect(headers.map(\.change) == [.renamed(similarity: 75), .modified])
        #expect(headers.map(\.oldPath) == [Self.path("one"), Self.path("three")])
        #expect(headers.map(\.newPath) == [Self.path("two"), Self.path("three")])
        #expect(headers.map(\.dissimilarity) == [nil, 88])
    }

    @Test(
        "prefixes are stripped only when the two sides use different letters",
        arguments: [
            ("c/x", "i/x", "x", "x"),          // diff.mnemonicPrefix
            ("w/d/x", "o/d/x", "d/x", "d/x"),
            ("b/x", "a/x", "x", "x"),          // -R swaps a/ and b/
            ("b/x", "b/x", "b/x", "b/x"),      // the same letter twice is a directory
            ("a/x", "x", "a/x", "x"),          // so is a letter facing a bare path
        ]
    )
    func prefixes(old: String, new: String, oldPath: String, newPath: String) {
        let header = Self.scan("""
            diff --git \(old) \(new)
            --- \(old)
            +++ \(new)
            @@ -1 +1 @@
            -a
            +b

            """).first?.header
        #expect(header?.oldPath == Self.path(oldPath))
        #expect(header?.newPath == Self.path(newPath))
    }

    @Test("unquoting undoes every C escape git writes and never rejects a byte")
    func unquoting() {
        let quoted = #""\a\b\f\n\r\t\v\"\\\101\303\251\777\q""#
        let bytes = PathQuoting.unquoted(Array(quoted.utf8)[...])
        #expect(bytes == [7, 8, 12, 10, 13, 9, 11, 34, 92, 65, 0xC3, 0xA9, 0xFF, UInt8(ascii: "q")])
        #expect(PathQuoting.unquoted(Array("plain path".utf8)[...]) == Array("plain path".utf8))
        // ChangedLines keys come from the same bytes, decoded lossily.
        let diff = """
            --- /dev/null
            +++ \(quoted)
            @@ -0,0 +1 @@
            +x

            """
        #expect(ChangedLines(diff: diff).lineSets == [String(decoding: bytes, as: UTF8.self): [1]])
    }
}
