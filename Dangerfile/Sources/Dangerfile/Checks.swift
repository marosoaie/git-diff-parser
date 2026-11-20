import StewardSwift

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
        valueTypes
        documentedPublicAPI
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

    /// Value types only (AGENTS.md): each class or actor in the library's
    /// sources is a warning at its declaration.
    static let valueTypes = Rule.swiftSource("Value types", in: "Sources/**/*.swift") { file in
        file.types
            .filter { $0.kind == .class || $0.kind == .actor }
            .map { .warning("\(Markdown.codeSpan($0.name)) isn't a value type (AGENTS.md).", at: $0.location) }
    }

    /// Every public symbol carries a doc comment (AGENTS.md): each public
    /// type, function or member in the library's sources without one is a
    /// warning at its declaration, in line order. A requirement of a public
    /// protocol is public, and so is a member of a `public extension`; a
    /// declaration inside a type that isn't public isn't, whatever it says.
    ///
    /// It checks the whole of each file the pull request changes, so that
    /// making a type, a protocol or an extension public reports what that
    /// exposes, at any depth. Top-level `let`, `var` and `typealias` aren't
    /// in steward-lang-swift's model, so it doesn't see them.
    static let documentedPublicAPI = Rule.swiftSource(
        "Documented public API", in: "Sources/**/*.swift", reporting: .changedFiles
    ) { file in
        let typeAccess = Dictionary(file.types.map { ($0.syntax.id, $0.access.level) }) { first, _ in first }
        // An extension's type may be declared in another file, so only types cap.
        let enclosingAccess = { (node: Syntax) in
            sequence(first: node, next: \.parent).compactMap { typeAccess[$0.id] }.min() ?? .open
        }
        let isUndocumented = { (access: AccessLevel, documentation: String?, node: Syntax) in
            documentation == nil && min(access.level, enclosingAccess(node)) >= .public
        }
        let types = file.types
            .filter { isUndocumented($0.access, $0.documentation, Syntax($0.syntax)) }
            .map { ($0.name, $0.location) }
        let functions = file.functions
            .filter { isUndocumented($0.access, $0.documentation, Syntax($0.syntax)) }
            .map { ($0.name, $0.location) }
        // A member function or type is in `functions` or `types` already.
        let members = file.memberBlocks
            .flatMap { block in block.members.map { (member: $0, block: Syntax(block.syntax)) } }
            .filter { $0.member.kind != .function && $0.member.kind != .type }
            .filter { isUndocumented($0.member.access, $0.member.documentation, $0.block) }
            .map { ($0.member.name, $0.member.location) }
        return (types + functions + members)
            .sorted { ($0.1.line ?? 0) < ($1.1.line ?? 0) }
            .map { name, location in
                .warning("Public \(Markdown.codeSpan(name)) has no doc comment (AGENTS.md).", at: location)
            }
    }

    /// Whether the file at `path` is a licence or a notice, by the names
    /// projects give them: `LICENSE`, `LICENCE.md`, `COPYING`, `NOTICE.txt`.
    static func isLicence(_ path: String) -> Bool {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map { $0.uppercased() } ?? ""
        return ["LICENSE", "LICENCE", "COPYING", "NOTICE"].contains { name.hasPrefix($0) }
    }
}
