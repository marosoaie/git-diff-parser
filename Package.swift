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
    // The 26 releases make `Span`, `Array.span`, and `UTF8Span` available
    // in the OS; Linux has no floor.
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v26), .watchOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "GitDiffKit", targets: ["GitDiffKit"]),
    ],
    targets: [
        // Unified git diffs → changed files and line ranges.
        .target(
            name: "GitDiffKit",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "GitDiffKitTests",
            dependencies: ["GitDiffKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ]
)
