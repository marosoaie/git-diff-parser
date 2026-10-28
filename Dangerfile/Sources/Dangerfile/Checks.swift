import Steward

/// The rules Steward checks this repository's pull requests with, in the
/// order they run and their findings show.
///
/// ci.yml's tests-and-lint job runs them through steward-action, which
/// posts the summary as a comment on the pull request; anywhere else,
/// `swift run --package-path Dangerfile` is a dry run that prints it.
@main
struct Checks: Dangerfile {
    static var rules: [Rule] {
        diagnostics
        noDependencies
        changelog
        thirdPartyNotices
    }

    /// The build's and SwiftLint's diagnostics on the lines the pull request
    /// changes, from the logs the job writes before it runs Steward. Warnings
    /// fail too: the build has none, and SwiftLint prints nothing
    /// (AGENTS.md).
    static let diagnostics = Rule.diagnosticsOnChangedLines(
        in: [.xcodebuild("build.log"), .swiftLint("swiftlint.log")],
        failingOn: .warning
    )

    /// GitDiffKit takes no dependencies (AGENTS.md), so each line a pull
    /// request adds to the root Package.swift that declares a package is a
    /// failure; adding one needs the maintainer's agreement, and this rule's
    /// change with it.
    static let noDependencies = Rule("No dependencies") { context in
        guard let manifest = context.git.file(at: "Package.swift") else { return [] }
        return manifest.lines.compactMap { line -> Finding? in
            guard line.info.kind == .addition, let number = line.info.newNumber,
                  String(decoding: line.content, as: UTF8.self).contains(".package(")
            else { return nil }
            return .failure("""
                GitDiffKit takes no dependencies: adding one needs the maintainer's agreement (AGENTS.md).
                """, at: Location(path: "Package.swift", line: number))
        }
    }

    /// A change to the library's sources, moving a file out of them
    /// included, comes with an entry under the changelog's "Unreleased".
    /// Deleting the changelog isn't one.
    static let changelog = Rule("Changelog") { context in
        let git = context.git
        let changed = git.createdFiles + git.modifiedFiles
        let touched = changed + git.deletedFiles + git.renamedFiles.map(\.from)
        guard touched.contains(where: { $0.hasPrefix("Sources/") }), !changed.contains("CHANGELOG.md")
        else { return [] }
        return [.warning("Add an entry to CHANGELOG.md, under Unreleased, for the changes under `Sources/`.")]
    }

    /// Material from another project comes with its licence and an entry in
    /// THIRD_PARTY_NOTICES.md (AGENTS.md), so a pull request that adds a
    /// licence or notice file without touching that list gets a warning at
    /// each one.
    static let thirdPartyNotices = Rule("Third-party notices") { context in
        let git = context.git
        guard !(git.createdFiles + git.modifiedFiles).contains("THIRD_PARTY_NOTICES.md") else { return [] }
        return git.createdFiles.filter(isLicence).map { path in
            .warning("Add an entry to THIRD_PARTY_NOTICES.md for the material this covers.", at: Location(path: path))
        }
    }

    /// Whether the file at `path` is a licence or a notice, by the names
    /// projects give them: `LICENSE`, `LICENCE.md`, `COPYING`, `NOTICE.txt`.
    static func isLicence(_ path: String) -> Bool {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map { $0.uppercased() } ?? ""
        return ["LICENSE", "LICENCE", "COPYING", "NOTICE"].contains { name.hasPrefix($0) }
    }
}
