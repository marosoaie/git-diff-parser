import ArgumentParser
import Foundation
import GitDiffKit

struct Changes: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the files and line numbers a diff adds or modifies.",
        discussion: """
            Line numbers are new-side (post-change) numbers. Deleted files and \
            pure renames produce no entries; modified lines count as added \
            because git represents a modification as a removal plus an addition.

            Example:
              git diff origin/main...HEAD | git-diff-parser changes -
            """
    )

    enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
        case json
        case text
    }

    @Argument(help: "Path to a unified diff, or '-' for stdin.")
    var diffPath: String

    @Option(help: "Output format: compact line ranges (json) or one greppable path:line per line (text).")
    var format: OutputFormat = .json

    func run() throws {
        let changes = try ChangedLines(streamingFrom: diffPath)

        switch format {
        case .json:
            let entries = changes.sortedPaths.map { path -> FileEntry in
                let ranges = changes.ranges(in: path)
                return FileEntry(
                    path: path,
                    lineCount: ranges.reduce(0) { $0 + $1.count },
                    ranges: ranges.map { RangeEntry(start: $0.lowerBound, end: $0.upperBound) }
                )
            }
            print(try JSON.encode(entries))
        case .text:
            var output = BufferedStandardOutput()
            for path in changes.sortedPaths {
                for range in changes.ranges(in: path) {
                    for line in range {
                        output.writeLine("\(path):\(line)")
                    }
                }
            }
            output.flush()
        }
    }
}

private struct RangeEntry: Encodable {
    var start: Int
    var end: Int
}

private struct FileEntry: Encodable {
    var path: String
    var lineCount: Int
    var ranges: [RangeEntry]
}
