import Foundation
import Testing

@Suite("Fixture cache location")
struct FixtureCacheTests {
    static let fallbackHome = URL(fileURLWithPath: "/root", isDirectory: true)

    static func cacheHome(_ environment: [String: String]) -> String {
        RealWorldFixtureStore.xdgCacheHome(environment: environment, fallbackHome: fallbackHome).path
    }

    @Test("an absolute XDG_CACHE_HOME wins over HOME")
    func absoluteXDGCacheHome() {
        #expect(Self.cacheHome(["XDG_CACHE_HOME": "/var/cache/ci", "HOME": "/home/tester"]) == "/var/cache/ci")
    }

    @Test(
        "an unset, empty, or relative XDG_CACHE_HOME falls back to $HOME/.cache",
        arguments: [[:], ["XDG_CACHE_HOME": ""], ["XDG_CACHE_HOME": "relative/cache"]]
    )
    func fallsBackToHomeDotCache(environment: [String: String]) {
        let withHome = environment.merging(["HOME": "/home/tester"]) { $1 }
        #expect(Self.cacheHome(withHome) == "/home/tester/.cache")
    }

    @Test(
        "without a usable HOME the passwd home directory is used",
        arguments: [[:], ["HOME": ""], ["HOME": "relative"]]
    )
    func fallsBackToPasswdHome(environment: [String: String]) {
        #expect(Self.cacheHome(environment) == "/root/.cache")
    }

    @Test("fixtures live in a git-diff-parser-tests folder under the platform cache root")
    func cacheDirectoryName() {
        let directory = RealWorldFixtureStore.cacheDirectory
        #expect(directory.lastPathComponent == "git-diff-parser-tests")
        #if canImport(Darwin)
        #expect(directory.path.hasSuffix("/Library/Caches/git-diff-parser-tests"))
        #else
        // CI restores the cache from $HOME/.cache, and $HOME there differs
        // from the passwd home that Foundation reports.
        let environment = ProcessInfo.processInfo.environment
        let expected = environment["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? environment["HOME"].map { "\($0)/.cache" }
        if let expected {
            #expect(directory.deletingLastPathComponent().standardizedFileURL.path
                == URL(fileURLWithPath: expected).standardizedFileURL.path)
        }
        #endif
    }
}
