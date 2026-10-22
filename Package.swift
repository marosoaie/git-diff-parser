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
