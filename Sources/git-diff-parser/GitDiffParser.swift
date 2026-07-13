import ArgumentParser

@main
struct GitDiffParser: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "git-diff-parser",
        abstract: """
            Map a git diff to its changed lines, and filter build/lint logs \
            down to the diagnostics that touch those lines.
            """,
        discussion: """
            Inputs are streamed, so arbitrarily large diffs and logs are fine. \
            Pass '-' as any file argument to read that input from stdin.
            """,
        version: "1.0.1",
        subcommands: [Changes.self, Filter.self]
    )
}
