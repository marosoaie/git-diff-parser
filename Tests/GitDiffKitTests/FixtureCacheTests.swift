import Foundation
import Testing

@Suite("Fixture cache location")
struct FixtureCacheTests {
    static let home = URL(fileURLWithPath: "/home/tester", isDirectory: true)

    @Test("XDG_CACHE_HOME wins when it is an absolute path")
    func absoluteXDGCacheHome() {
        let root = RealWorldFixtureStore.xdgCacheHome(
            environment: ["XDG_CACHE_HOME": "/var/cache/ci"], home: Self.home
        )
        #expect(root.path == "/var/cache/ci")
    }

    @Test(
        "an unset, empty, or relative XDG_CACHE_HOME falls back to ~/.cache",
        arguments: [[:], ["XDG_CACHE_HOME": ""], ["XDG_CACHE_HOME": "relative/cache"]]
    )
    func fallsBackToDotCache(environment: [String: String]) {
        let root = RealWorldFixtureStore.xdgCacheHome(environment: environment, home: Self.home)
        #expect(root.path == "/home/tester/.cache")
    }

    @Test("fixtures live in a git-diff-parser-tests folder under the platform cache root")
    func cacheDirectoryName() {
        let directory = RealWorldFixtureStore.cacheDirectory
        #expect(directory.lastPathComponent == "git-diff-parser-tests")
        #if canImport(Darwin)
        #expect(directory.path.hasSuffix("/Library/Caches/git-diff-parser-tests"))
        #else
        let expected = RealWorldFixtureStore.xdgCacheHome(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        #expect(directory.deletingLastPathComponent().path == expected.path)
        #endif
    }
}
