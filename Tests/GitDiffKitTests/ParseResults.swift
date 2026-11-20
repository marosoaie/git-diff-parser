@testable import GitDiffKit

/// One input parsed by the event recorder and by each of the three
/// collectors, the full model with its own options.
struct ParseResults: Equatable {
    var events: [EventRecorder.Event]
    var changedLineNumbers: ChangedLineNumbers
    var summary: DiffSummary
    var diff: Diff

    init(of bytes: [UInt8], chunkSizes: [Int] = [.max]) {
        events = DiffEventParser.collect(EventRecorder(), from: bytes, chunkSizes: chunkSizes).events
        changedLineNumbers = DiffEventParser
            .collect(ChangedLineNumbers.Collector(), from: bytes, chunkSizes: chunkSizes)
            .changedLineNumbers
        summary = DiffEventParser.collect(DiffSummary.Collector(), from: bytes, chunkSizes: chunkSizes).summary
        diff = DiffEventParser.collect(Diff.Collector(), from: bytes, chunkSizes: chunkSizes, options: .fullModel)
            .diff
    }

    /// The results that differ from `other`'s, by name.
    func differences(from other: Self) -> [String] {
        [
            events == other.events ? nil : "events",
            changedLineNumbers == other.changedLineNumbers ? nil : "ChangedLineNumbers",
            summary == other.summary ? nil : "DiffSummary",
            diff == other.diff ? nil : "Diff",
        ].compactMap(\.self)
    }
}
