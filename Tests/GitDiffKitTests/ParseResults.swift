@testable import GitDiffKit

/// One input parsed by the event recorder and by each of the three
/// collectors, the full model with its own options.
struct ParseResults: Equatable {
    var events: [EventRecorder.Event]
    var changedLines: ChangedLines
    var summary: DiffSummary
    var diff: Diff

    init(of bytes: [UInt8], chunkSizes: [Int] = [.max]) {
        events = DiffEventParser.collect(EventRecorder(), from: bytes, chunkSizes: chunkSizes).events
        changedLines = DiffEventParser.collect(ChangedLines.Collector(), from: bytes, chunkSizes: chunkSizes)
            .changedLines
        summary = DiffEventParser.collect(DiffSummary.Collector(), from: bytes, chunkSizes: chunkSizes).summary
        diff = DiffEventParser.collect(Diff.Collector(), from: bytes, chunkSizes: chunkSizes, options: .fullModel)
            .diff
    }

    /// The results that differ from `other`'s, by name.
    func differences(from other: Self) -> [String] {
        [
            events == other.events ? nil : "events",
            changedLines == other.changedLines ? nil : "ChangedLines",
            summary == other.summary ? nil : "DiffSummary",
            diff == other.diff ? nil : "Diff",
        ].compactMap(\.self)
    }
}
