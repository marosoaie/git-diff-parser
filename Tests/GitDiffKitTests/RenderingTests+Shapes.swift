@testable import GitDiffKit

extension RenderingTests {
    /// Shapes of real diffs, each rendered back exactly. The tests take the
    /// case, not the text, to keep swift-testing's printed arguments short.
    enum Shape: CaseIterable {
        case modification
        case creationAndDeletion
        case emptyFiles
        case pureRename
        case renameWithEdits
        case copy
        case modeChangeOnly
        case modeChangeWithEdits
        case symlinkAndSubmodule
        case binaryFilesDiffer
        case binaryPatch
        case noNewlineBothSides
        case noNewlineAddedBack
        case implicitCounts
        case zeroContext
        case quotedPaths
        case notUTF8
        case crlfFile
        case crlfTransport
        case bareContextLines
        case gitShow
        case formatPatch
        case logWithSeveralCommits
        case plainDiff
        case oldSideWithoutNewSide
        case junkBetweenHunks

        var bytes: [UInt8] {
            switch self {
            case .notUTF8:
                RenderingTests.bytes("--- a/f\n+++ b/f\n@@ -1 +1 @@\n-caf") + [0xE9]
                    + RenderingTests.bytes("\n+caf") + [0xE9, 0xFF, 0x0A]
            case .crlfTransport:
                RenderingTests.bytes(Shape.statuses.replacing("\n", with: "\r\n")
                    + LineEndingTests.crlfWithMarkers)
            default:
                RenderingTests.bytes(text)
            }
        }

        private static let statuses = DiffSummaryTests.statuses
    }
}

extension RenderingTests.Shape {
    /// The shape's diff, for every case that is text.
    fileprivate var text: String {
        switch self {
        case .modification: StreamingTests.fixture
        case .creationAndDeletion: """
            diff --git a/added.txt b/added.txt
            new file mode 100644
            index 0000000..3333333
            --- /dev/null
            +++ b/added.txt
            @@ -0,0 +1,2 @@
            +new
            +file
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100755
            index 4444444..0000000
            --- a/gone.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye

            """
        case .emptyFiles: """
            diff --git a/empty.txt b/empty.txt
            new file mode 100644
            index 0000000..e69de29
            diff --git a/empty-gone.txt b/empty-gone.txt
            deleted file mode 100644
            index e69de29..0000000

            """
        case .pureRename: """
            diff --git a/old name.txt b/new name.txt
            similarity index 100%
            rename from old name.txt
            rename to new name.txt

            """
        case .renameWithEdits: """
            diff --git a/dir/sub/moved.txt b/dir/other/moved.txt
            similarity index 90%
            rename from dir/sub/moved.txt
            rename to dir/other/moved.txt
            index 5555555..6666666 100644
            --- a/dir/sub/moved.txt
            +++ b/dir/other/moved.txt
            @@ -4,3 +4,3 @@ line 3
             line 4
            -line 5
            +LINE 5
             line 6

            """
        case .copy: """
            diff --git a/source.txt b/copy.txt
            similarity index 90%
            copy from source.txt
            copy to copy.txt
            index 5555555..7777777 100644
            --- a/source.txt
            +++ b/copy.txt
            @@ -1,3 +1,3 @@
             one
            -two
            +TWO
             three

            """
        case .modeChangeOnly: """
            diff --git a/run.sh b/run.sh
            old mode 100644
            new mode 100755

            """
        case .modeChangeWithEdits: """
            diff --git a/script.sh b/script.sh
            old mode 100644
            new mode 100755
            index 1111111..2222222
            --- a/script.sh
            +++ b/script.sh
            @@ -1 +1 @@
            -echo one
            +echo two

            """
        case .symlinkAndSubmodule: """
            diff --git a/newlink b/newlink
            new file mode 120000
            index 0000000..1111111
            --- /dev/null
            +++ b/newlink
            @@ -0,0 +1 @@
            +keep.txt
            \\ No newline at end of file
            diff --git a/sub b/sub
            new file mode 160000
            index 0000000..0123456
            --- /dev/null
            +++ b/sub
            @@ -0,0 +1 @@
            +Subproject commit 0123456789abcdef0123456789abcdef01234567

            """
        case .binaryFilesDiffer: """
            diff --git a/image.png b/image.png
            index 7777777..8888888 100644
            Binary files a/image.png and b/image.png differ
            diff --git a/new.bin b/new.bin
            new file mode 100644
            index 0000000..9999999
            Binary files /dev/null and b/new.bin differ

            """
        case .binaryPatch: DiffTests.binaryPatch
        case .noNewlineBothSides: """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -1,2 +1,2 @@
             x
            -y
            \\ No newline at end of file
            +z
            \\ No newline at end of file

            """
        case .noNewlineAddedBack: """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -1 +1 @@
            -last
            \\ No newline at end of file
            +last

            """
        case .implicitCounts: """
            --- a/f
            +++ b/f
            @@ -1 +1,2 @@
            -a
            +a
            +b
            @@ -5,1 +6 @@ explicit one, implicit one
            -e
            +E

            """
        case .zeroContext: """
            diff --git a/f b/f
            --- a/f
            +++ b/f
            @@ -2,0 +3,2 @@ context
            +inserted
            +lines
            @@ -9 +10,0 @@
            -removed

            """
        case .quotedPaths: #"""
            diff --git "a/tab\there.txt" "b/tab\there.txt"
            new file mode 100644
            index 0000000..1111111
            --- /dev/null
            +++ "b/tab\there.txt"
            @@ -0,0 +1 @@
            +t
            diff --git "a/caf\351 x.txt" "b/caf\351 y.txt"
            similarity index 100%
            rename from "caf\351 x.txt"
            rename to "caf\351 y.txt"

            """#
        case .notUTF8: ""
        case .crlfFile: """
            --- a/f.txt
            +++ b/f.txt
            @@ -1,2 +1,2 @@ int main()
             a\r
            -b\r
            +c
            \\ No newline at end of file

            """
        case .crlfTransport: ""
        case .bareContextLines: "--- a/f\n+++ b/f\n@@ -1,5 +1,5 @@\n one\n\n-two\n+TWO\n\n\r\n"
        case .gitShow: DiffSummaryTests.statuses
        case .formatPatch: """
            From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001
            From: A U Thor <author@example.com>
            Date: Mon, 26 Oct 2026 01:00:00 +0100
            Subject: [PATCH] Touch a file

            ---
             a.txt | 2 +-
             1 file changed, 1 insertion(+), 1 deletion(-)

            diff --git a/a.txt b/a.txt
            index 1111111..2222222 100644
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -a
            +A
            --\u{20}
            2.50.0


            """
        case .logWithSeveralCommits: DiffTests.logWithCommits
        case .plainDiff: """
            Only in old: gone.txt
            diff -ruN old/f.txt new/f.txt
            --- old/f.txt\t2026-10-26 01:00:00.000000000 +0100
            +++ new/f.txt\t2026-10-26 01:00:01.000000000 +0100
            @@ -1 +1 @@
            -x
            +y
            --- old/g.txt\t2026-10-26 01:00:00.000000000 +0100
            +++ new/g.txt\t1970-01-01 01:00:00.000000000 +0100
            @@ -1 +0,0 @@
            -g

            """
        case .oldSideWithoutNewSide: """
            --- a/f
            +++ b/f
            @@ -1 +1 @@
            -a
            +b
            --- not a file
            text

            """
        case .junkBetweenHunks: """
            diff --git a/f b/f
            --- a/f
            +++ b/f
            junk before the first hunk
            @@ -1 +1 @@
            -a
            +b
            junk between hunks
            @@ -5 +5 @@
            -e
            +E
            junk after the last hunk

            """
        }
    }
}
