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
        .executable(name: "git-diff-parser", targets: ["git-diff-parser"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "GitDiffKit",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "git-diff-parser",
            dependencies: [
                "GitDiffKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
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
