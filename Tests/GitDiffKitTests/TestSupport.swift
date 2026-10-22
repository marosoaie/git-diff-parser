@testable import GitDiffKit

extension ChangedLines {
    /// Expanded per-file line sets — convenient for asserting on small fixtures.
    var lineSets: [String: Set<Int>] {
        files.mapValues { Set($0.ranges.flatMap { Array($0) }) }
    }
}
