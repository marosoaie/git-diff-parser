import Testing
@testable import GitDiffKit

@Suite("DiffParser")
struct DiffParserTests {
    @Test("modified file records added line numbers on the new side")
    func modifiedFile() {
        let diff = #"""
        diff --git a/Sources/App/Foo.swift b/Sources/App/Foo.swift
        index 1234567..89abcde 100644
        --- a/Sources/App/Foo.swift
        +++ b/Sources/App/Foo.swift
        @@ -10,7 +10,8 @@ struct Foo {
             let a = 1
        -    let b = 2
        +    let b = 22
        +    let c = 3
             let d = 4
         }
        """#
        let changes = ChangedLines(diff: diff)
        #expect(changes.lineSets == ["Sources/App/Foo.swift": [11, 12]])
    }

    @Test("multiple hunks and multiple files")
    func multipleHunksAndFiles() {
        let diff = #"""
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -1,3 +1,4 @@
        +import Foundation
         struct A {
             let x = 1
         }
        @@ -20,2 +21,3 @@
         func f() {
        +    print("hi")
         }
        diff --git a/B.swift b/B.swift
        --- a/B.swift
        +++ b/B.swift
        @@ -5 +5 @@
        -let old = 1
        +let new = 1
        """#
        let changes = ChangedLines(diff: diff)
        #expect(changes.lineSets == [
            "A.swift": [1, 22],
            "B.swift": [5],
        ])
    }

    @Test("new file has every line marked")
    func newFile() {
        let diff = #"""
        diff --git a/New.swift b/New.swift
        new file mode 100644
        index 0000000..abc1234
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1,3 @@
        +line one
        +line two
        +line three
        """#
        let changes = ChangedLines(diff: diff)
        #expect(changes.lineSets == ["New.swift": [1, 2, 3]])
    }

    @Test("deleted file produces no entries")
    func deletedFile() {
        let diff = #"""
        diff --git a/Gone.swift b/Gone.swift
        deleted file mode 100644
        --- a/Gone.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -bye
        -bye
        """#
        #expect(ChangedLines(diff: diff).isEmpty)
    }

    @Test("pure rename produces no entries, rename with edits uses the new path")
    func renames() {
        let pureRename = #"""
        diff --git a/Old.swift b/Renamed.swift
        similarity index 100%
        rename from Old.swift
        rename to Renamed.swift
        """#
        #expect(ChangedLines(diff: pureRename).isEmpty)

        let renameWithEdit = #"""
        diff --git a/Old.swift b/Renamed.swift
        similarity index 90%
        rename from Old.swift
        rename to Renamed.swift
        --- a/Old.swift
        +++ b/Renamed.swift
        @@ -3,2 +3,2 @@
        -old line
        +new line
         context
        """#
        #expect(ChangedLines(diff: renameWithEdit).lineSets == ["Renamed.swift": [3]])
    }

    @Test("binary files are skipped")
    func binaryFile() {
        let diff = #"""
        diff --git a/img.png b/img.png
        index 1234567..89abcde 100644
        Binary files a/img.png and b/img.png differ
        """#
        #expect(ChangedLines(diff: diff).isEmpty)
    }

    @Test("added content that itself looks like diff syntax is not misparsed")
    func addedLinesLookingLikeHeaders() {
        // The added lines start with "+++ " and "@@ " once the leading '+'
        // marker is included; hunk length bookkeeping must keep us in the hunk.
        let diff = #"""
        diff --git a/notes.md b/notes.md
        --- a/notes.md
        +++ b/notes.md
        @@ -1,2 +1,4 @@
         first
        +++ extra plus line
        +@@ fake hunk @@
         last
        """#
        let changes = ChangedLines(diff: diff)
        #expect(changes.lineSets == ["notes.md": [2, 3]])
    }

    @Test("no newline marker does not shift line numbers")
    func noNewlineMarker() {
        let diff = #"""
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        \ No newline at end of file
        +new
        \ No newline at end of file
        """#
        #expect(ChangedLines(diff: diff).lineSets == ["f.txt": [2]])
    }

    @Test("empty context lines (stripped trailing space) still advance counters")
    func emptyContextLine() {
        // Some pipelines strip the single space marker from blank context
        // lines; the parser must treat the empty line as context.
        let diff = "diff --git a/f.txt b/f.txt\n"
            + "--- a/f.txt\n"
            + "+++ b/f.txt\n"
            + "@@ -1,3 +1,4 @@\n"
            + " a\n"
            + "\n"
            + "+added\n"
            + " b\n"
        #expect(ChangedLines(diff: diff).lineSets == ["f.txt": [3]])
    }

    @Test("quoted paths with octal escapes are decoded")
    func quotedPath() {
        let diff = #"""
        diff --git "a/a\303\244.swift" "b/a\303\244.swift"
        --- "a/a\303\244.swift"
        +++ "b/a\303\244.swift"
        @@ -1 +1 @@
        -x
        +y
        """#
        #expect(ChangedLines(diff: diff).lineSets == ["aä.swift": [1]])
    }

    @Test("diffs generated with --no-prefix keep bare paths")
    func noPrefix() {
        let diff = #"""
        diff --git Sources/Foo.swift Sources/Foo.swift
        --- Sources/Foo.swift
        +++ Sources/Foo.swift
        @@ -1 +1,2 @@
         x
        +y
        """#
        #expect(ChangedLines(diff: diff).lineSets == ["Sources/Foo.swift": [2]])
    }

    @Test("git's full C-style escape set is decoded in quoted paths")
    func controlCharacterEscapes() {
        let expected = String(decoding: [0x07, 0x08, 0x0B, 0x0C], as: UTF8.self) + ".txt"
        #expect(DiffParser.unquote(#""\a\b\v\f.txt""#) == expected)
    }

    @Test("mnemonic destination prefixes are stripped like the default b/")
    func mnemonicPrefixes() {
        #expect(DiffParser.parseFileHeaderPath("w/Sources/Foo.swift") == "Sources/Foo.swift")
        #expect(DiffParser.parseFileHeaderPath("i/x") == "x")
        #expect(DiffParser.parseFileHeaderPath("c/x", pairedWith: .letter("i")) == "x")
        #expect(DiffParser.parseFileHeaderPath("o/x", pairedWith: .devNull) == "x")
        // Only single-letter prefix components qualify.
        #expect(DiffParser.parseFileHeaderPath("workspace/file") == "workspace/file")
    }

    @Test("git diff -R's swapped a/ prefix is stripped on the new side")
    func reversedDiffPrefix() {
        let diff = "diff --git b/f.txt a/f.txt\n"
            + "--- b/f.txt\n"
            + "+++ a/f.txt\n"
            + "@@ -1 +1,2 @@\n"
            + " x\n"
            + "+y\n"
        #expect(ChangedLines(diff: diff).lineSets == ["f.txt": [2]])
    }

    @Test("--no-prefix paths in real single-letter directories are kept intact")
    func noPrefixSingleLetterDirectory() {
        // Real git prefix pairs always differ; the same letter on both
        // header sides is a genuine directory, not a prefix.
        let diff = "diff --git c/w/f1.txt c/w/f1.txt\n"
            + "--- c/w/f1.txt\n"
            + "+++ c/w/f1.txt\n"
            + "@@ -1 +1,2 @@\n"
            + " x\n"
            + "+y\n"
        #expect(ChangedLines(diff: diff).lineSets == ["c/w/f1.txt": [2]])
    }

    @Test("hunk header with omitted counts defaults to 1")
    func hunkHeaderDefaults() {
        let header = DiffParser.parseHunkHeader(ArraySlice("@@ -3 +7 @@ func x()".utf8))
        #expect(header?.newStart == 7)
        #expect(header?.oldCount == 1)
        #expect(header?.newCount == 1)
    }
}
