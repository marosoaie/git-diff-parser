import Foundation
import Testing
@testable import GitDiffKit

/// Coloured renderings of the fixture against the plain ones.
extension GitApplyOracleTests {
    // With metadata in `normal`, a `diff ` line's only code is its reset.
    @Test(
        "a coloured diff parses as the same full model as the plain one, for any chunking and metadata colour",
        arguments: variants, ["bold", "normal"]
    )
    func coloured(variant: Variant, metadataColour: String) throws {
        let plain = try Self.withDiff(variant) { diff, _ in Diff.of(try Array(Data(contentsOf: diff))) }
        var coloured = variant
        coloured.gitOptions += ["-c", "color.diff.meta=\(metadataColour)"]
        coloured.diffOptions += ["--color=always", "--color-moved", "--ws-error-highlight=all"]
        try Self.withDiff(coloured) { diff, _ in
            let bytes = try Array(Data(contentsOf: diff))
            #expect(bytes.contains(DiffSyntax.escape))
            #expect(Diff.of(bytes) == plain)
            #expect(Diff.of(bytes, chunkSize: 1) == plain)
        }
    }

    // Commit text before the first file is left alone, so a --stat graph
    // keeps its colour there.
    @Test(
        "coloured git show, git log -p, and git format-patch output has the plain output's files",
        arguments: [
            ["show", "--stat", "-p", "--binary", "main"],
            ["log", "-p", "--binary", "main"],
            ["format-patch", "--stdout", "--binary", "--root", "main"],
        ]
    )
    func colouredLog(arguments: [String]) throws {
        let plain = try Self.withOutput(of: arguments) { output, _ in Diff.of(try Array(Data(contentsOf: output))) }
        try Self.withOutput(of: arguments + ["--color=always"]) { output, _ in
            let coloured = Diff.of(try Array(Data(contentsOf: output)))
            #expect(coloured.files.count > 20)
            #expect(coloured.files == plain.files)
            #expect(coloured.damage == plain.damage)
        }
    }
}
