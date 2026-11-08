import Testing
@testable import GitDiffKit

/// Coloured output, with git's escapes spelled out; `GitApplyOracleTests`
/// checks git's own against the plain diff.
@Suite("Coloured diffs")
struct ColouredDiffTests {
    /// `git -c color.ui=always diff`, with a function heading, a
    /// highlighted trailing space, and a missing final newline.
    static let coloured = """
        \u{1B}[1mdiff --git a/a.swift b/a.swift\u{1B}[m
        \u{1B}[1mindex 31d074d..247e18d 100644\u{1B}[m
        \u{1B}[1m--- a/a.swift\u{1B}[m
        \u{1B}[1m+++ b/a.swift\u{1B}[m
        \u{1B}[36m@@ -1,3 +1,3 @@\u{1B}[m \u{1B}[mfunc a() {\u{1B}[m
         one\u{1B}[m
        \u{1B}[31m-two\u{1B}[m
        \u{1B}[32m+\u{1B}[m\u{1B}[32mTWO\u{1B}[m\u{1B}[41m \u{1B}[m
         three\u{1B}[m
        \\ No newline at end of file\u{1B}[m

        """

    static let plain = """
        diff --git a/a.swift b/a.swift
        index 31d074d..247e18d 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,3 @@ func a() {
         one
        -two
        +TWO\u{20}
         three
        \\ No newline at end of file

        """

    /// A plain file whose content holds colour codes, from git or from
    /// `diff -u`.
    static let plainWithCodes = [
        """
        diff --git a/log.txt b/log.txt
        --- a/log.txt
        +++ b/log.txt
        @@ -1 +1,2 @@
         \u{1B}[1mbold\u{1B}[m
        +\u{1B}[31mred\u{1B}[m

        """,
        """
        --- a/log.txt
        +++ b/log.txt
        @@ -1 +1,2 @@
         \u{1B}[1mbold\u{1B}[m
        +\u{1B}[31mred\u{1B}[m

        """,
    ]

    @Test("a coloured diff parses as the plain one, for any chunking", arguments: [1, 7, Int.max])
    func colouredParsesAsPlain(chunkSize: Int) {
        #expect(Diff.of(Array(Self.coloured.utf8), chunkSize: chunkSize) == Diff.of(Array(Self.plain.utf8)))
    }

    @Test(
        "a plain file keeps the colour codes its content holds, even after a coloured file",
        arguments: plainWithCodes
    )
    func plainKeepsCodes(plainWithCodes: String) {
        let alone = Array(plainWithCodes.utf8)
        #expect([UInt8](rendering: Diff.of(alone)) == alone)
        let afterColoured = Diff.of(Array((Self.coloured + plainWithCodes).utf8))
        #expect(afterColoured.files.last == Diff.of(alone).files.first)
    }

    @Test(
        "only SGR sequences are removed",
        arguments: [
            ("\u{1B}[1;31mred\u{1B}[m", "red"),
            ("\u{1B}[38:2:255:0:0mx", "x"),
            ("\u{1B}[2Kx", "\u{1B}[2Kx"),
            ("\u{1B}]8;;url\u{1B}\\x", "\u{1B}]8;;url\u{1B}\\x"),
            ("x\u{1B}[1", "x\u{1B}[1"),
            ("\u{1B}\u{1B}[mx", "\u{1B}x"),
        ]
    )
    func onlySGR(input: String, expected: String) {
        let plain = DiffEventParser<Diff.Collector>.removingColourCodes(from: Array(input.utf8)[...])
        #expect(String(decoding: plain, as: UTF8.self) == expected)
    }
}
