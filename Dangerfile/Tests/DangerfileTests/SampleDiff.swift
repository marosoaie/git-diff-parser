/// Pull requests' diffs as `git diff` writes them, for the rule tests.
enum SampleDiff {
    /// An edit to the library's sources, which adds its line 2.
    static let source = """
        diff --git a/Sources/GitDiffKit/Diff.swift b/Sources/GitDiffKit/Diff.swift
        index 1111111..2222222 100644
        --- a/Sources/GitDiffKit/Diff.swift
        +++ b/Sources/GitDiffKit/Diff.swift
        @@ -1,2 +1,3 @@
         /// A diff.
        +let unused = 1
         public struct Diff {}

        """

    /// The same edit, with its changelog entry.
    static let sourceWithChangelog = source + """
        diff --git a/CHANGELOG.md b/CHANGELOG.md
        index 3333333..4444444 100644
        --- a/CHANGELOG.md
        +++ b/CHANGELOG.md
        @@ -1,2 +1,3 @@
         ## Unreleased
        +- Parse more.
         ## 0.2.0

        """

    /// The same edit, deleting the changelog.
    static let sourceDeletingChangelog = source + """
        diff --git a/CHANGELOG.md b/CHANGELOG.md
        deleted file mode 100644
        index 3333333..0000000
        --- a/CHANGELOG.md
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -## Unreleased
        -## 0.2.0

        """

    /// A file moved out of `Sources/`, unchanged.
    static let moveOutOfSources = """
        diff --git a/Sources/GitDiffKit/Legacy.swift b/Archive/Legacy.swift
        similarity index 100%
        rename from Sources/GitDiffKit/Legacy.swift
        rename to Archive/Legacy.swift

        """

    /// An edit to the README.
    static let readme = """
        diff --git a/README.md b/README.md
        index 5555555..6666666 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1,2 @@
         # git-diff-parser
        +Parses diffs.

        """

    /// A dependency added to the library's manifest, at its line 4.
    static let dependency = """
        diff --git a/Package.swift b/Package.swift
        index 7777777..8888888 100644
        --- a/Package.swift
        +++ b/Package.swift
        @@ -1,4 +1,5 @@
         let package = Package(
             name: "git-diff-parser",
             dependencies: [
        +        .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
             ],

        """

    /// A dependency removed from the library's manifest, beside one that
    /// stays as context.
    static let dependencyRemoved = """
        diff --git a/Package.swift b/Package.swift
        index 8888888..9999999 100644
        --- a/Package.swift
        +++ b/Package.swift
        @@ -2,4 +2,3 @@
             dependencies: [
                 .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
        -        .package(url: "https://github.com/apple/swift-algorithms", from: "1.0.0"),
             ],

        """

    /// Another edit to the library's manifest, and a dependency added to
    /// the Dangerfile's.
    static let otherManifestEdits = """
        diff --git a/Package.swift b/Package.swift
        index 7777777..9999999 100644
        --- a/Package.swift
        +++ b/Package.swift
        @@ -1,3 +1,3 @@
         let package = Package(
        -    name: "git-diff-parser",
        +    name: "git-diff-parser", // .product(name: "GitDiffKit", package: "git-diff-parser")
             dependencies: [
        diff --git a/Dangerfile/Package.swift b/Dangerfile/Package.swift
        index aaaaaaa..bbbbbbb 100644
        --- a/Dangerfile/Package.swift
        +++ b/Dangerfile/Package.swift
        @@ -1,2 +1,3 @@
             dependencies: [
        +        .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
             ],

        """

    /// A fixture from another project, with its notice beside it.
    static let fixtureWithNotice = """
        diff --git a/Tests/Fixtures/upstream.diff b/Tests/Fixtures/upstream.diff
        new file mode 100644
        index 0000000..5555555
        --- /dev/null
        +++ b/Tests/Fixtures/upstream.diff
        @@ -0,0 +1 @@
        +diff --git a/x b/x
        diff --git a/Tests/Fixtures/NOTICE b/Tests/Fixtures/NOTICE
        new file mode 100644
        index 0000000..6666666
        --- /dev/null
        +++ b/Tests/Fixtures/NOTICE
        @@ -0,0 +1 @@
        +Copyright (c) Upstream authors

        """

    /// The same, with its entry in the list of third-party notices.
    static let fixtureWithNoticeListed = fixtureWithNotice + """
        diff --git a/THIRD_PARTY_NOTICES.md b/THIRD_PARTY_NOTICES.md
        index 7777777..8888888 100644
        --- a/THIRD_PARTY_NOTICES.md
        +++ b/THIRD_PARTY_NOTICES.md
        @@ -1 +1,2 @@
         | Path | Upstream |
        +| `Tests/Fixtures/upstream.diff` | Upstream |

        """
}
