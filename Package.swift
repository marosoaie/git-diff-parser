// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "git-diff-parser",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitDiffKit", targets: ["GitDiffKit"]),
        .library(name: "BuildLogKit", targets: ["BuildLogKit"]),
        .library(name: "DiffDiagnostics", targets: ["DiffDiagnostics"]),
        .executable(name: "git-diff-parser", targets: ["git-diff-parser"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Chunk-to-line plumbing shared by the streaming parsers; internal
        // to the package (not a product).
        .target(
            name: "StreamParsing",
            swiftSettings: swiftSettings
        ),
        // Unified git diffs → changed files and line ranges.
        .target(
            name: "GitDiffKit",
            dependencies: ["StreamParsing"],
            swiftSettings: swiftSettings
        ),
        // Build/lint logs → diagnostics, with tool-specific parsers for
        // xcodebuild, SwiftLint, and SwiftFormat.
        .target(
            name: "BuildLogKit",
            dependencies: ["StreamParsing"],
            swiftSettings: swiftSettings
        ),
        // The join: which diagnostics land on lines a diff touches.
        .target(
            name: "DiffDiagnostics",
            dependencies: ["GitDiffKit", "BuildLogKit"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "git-diff-parser",
            dependencies: [
                "GitDiffKit",
                "BuildLogKit",
                "DiffDiagnostics",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "GitDiffKitTests",
            dependencies: ["GitDiffKit", "BuildLogKit", "DiffDiagnostics"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ]
)
