// swift-tools-version: 6.2
// The checks Steward runs on this repository's pull requests, in ci.yml's
// tests-and-lint job (swift-steward's docs/quickstart.md has the layout).
// The one package here with dependencies: GitDiffKit's own Package.swift
// never names it, so the library's users never resolve, fetch or build
// anything from it (AGENTS.md).
import PackageDescription

let package = Package(
    name: "Dangerfile",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Steward 0.4.x, at the release Package.resolved pins: `swift package
        // update --package-path Dangerfile` takes its fixes. Under 0.x a
        // minor release may break, so moving to the next one is an edit here.
        .package(url: "https://github.com/marosoaie/swift-steward.git", .upToNextMinor(from: "0.4.0")),
        // Rules about the library's Swift source, parsed with swift-syntax.
        // Each 0.x minor release builds against one Steward minor release,
        // so moving to Steward's next one waits for a release of this that
        // takes it.
        .package(url: "https://github.com/marosoaie/steward-lang-swift.git", .upToNextMinor(from: "0.3.0")),
    ],
    targets: [
        .executableTarget(
            name: "Dangerfile",
            dependencies: [
                .product(name: "Steward", package: "swift-steward"),
                .product(name: "StewardSwift", package: "steward-lang-swift"),
            ]
        ),
        .testTarget(
            name: "DangerfileTests",
            dependencies: ["Dangerfile", .product(name: "StewardTesting", package: "swift-steward")]
        ),
    ]
)
