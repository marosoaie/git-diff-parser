import Foundation
import Testing

@Suite("git apply --numstat oracle")
struct GitNumstatTests {
    static let patch = """
        diff --git a/top.txt b/top.txt
        new file mode 100644
        --- /dev/null
        +++ b/top.txt
        @@ -0,0 +1,2 @@
        +one
        +two

        """

    @Test("a diff cached inside another repository's subfolder still counts every path")
    func cacheInsideWorkTree() throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-numstat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        let cache = repository.appendingPathComponent("cache/git-diff-parser-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        _ = try Subprocess.output(of: ["git", "init", "--quiet", repository.path])

        let diff = cache.appendingPathComponent("fixture.diff")
        try Data(Self.patch.utf8).write(to: diff)

        #expect(try GitNumstat.addedLineCounts(forDiffAt: diff) == ["top.txt": 2])
    }
}
