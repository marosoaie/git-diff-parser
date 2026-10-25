import Testing
@testable import GitDiffKit

extension ChangedLines {
    /// Expanded per-file line sets — convenient for asserting on small fixtures.
    var lineSets: [String: Set<Int>] {
        files.mapValues { Set($0.ranges.flatMap { Array($0) }) }
    }
}

extension FileHeaderScanner {
    /// The files of `bytes`, fed to a scanner in `chunkSize`-byte chunks.
    static func files(in bytes: [UInt8], chunkSize: Int = .max) -> [File] {
        var scanner = FileHeaderScanner()
        stride(from: 0, to: bytes.count, by: chunkSize).forEach { start in
            scanner.consume(bytes[start..<(start + min(chunkSize, bytes.count - start))])
        }
        return scanner.finalize()
    }
}

/// Comparisons against an oracle's output that report where results part
/// ways rather than dumping both.
enum Oracle {
    /// Compares line by line, so a failure names the first lines that differ
    /// instead of printing two whole summaries.
    static func expectEqualLines(
        _ ours: [UInt8], _ oracle: [UInt8], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let split = { (bytes: [UInt8]) in
            bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
        }
        expectEqualEntries(split(ours), split(oracle), sourceLocation: sourceLocation)
    }

    static func expectEqualEntries<Entry: Equatable>(
        _ ours: [Entry], _ oracle: [Entry], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let firstDifference = zip(ours, oracle).prefix { $0 == $1 }.count
        guard ours.count != oracle.count || firstDifference < ours.count else { return }
        let window = firstDifference..<(firstDifference + 3)
        Issue.record(
            """
            \(ours.count) entries against git's \(oracle.count); first difference at \(firstDifference): \
            ours \(ours[window.clamped(to: ours.indices)]), \
            git's \(oracle[window.clamped(to: oracle.indices)])
            """,
            sourceLocation: sourceLocation
        )
    }
}
