@testable import GitDiffKit

/// A clean window's parse, and the rules any mutation of it must keep.
///
/// Whatever the edit, parsing must not trap, its results must not depend
/// on chunking, the collectors must agree with the events (and, without
/// damage, the model with its own rendering), and the files outside the
/// mutation's footprint (`DiffWindow.footprint(of:)`) must come out
/// exactly as in the clean parse: their events, their `ChangedLines`
/// entries, their `DiffSummary` and `Diff` files. A `diff ` line resets
/// the parser, so damage can't spread past the next intact one; before
/// the edit, the input is the same.
struct MutationCheck {
    let window: DiffWindow
    let clean: ParseResults
    let cleanEvents: LineEvents

    struct SetupError: Error, CustomStringConvertible {
        var description: String
    }

    /// A parse's events, and how many it had sent before each line, then
    /// after the last.
    struct LineEvents {
        var events: [EventRecorder.Event]
        var eventsBeforeLine: [Int]
    }

    /// Parses `window`, or says why it isn't clean: it must parse without
    /// damage, one file per `diff ` line, the same line by line as whole,
    /// and render back to its own bytes.
    static func make(_ window: DiffWindow) -> Result<Self, SetupError> {
        let check = Self(window: window, clean: ParseResults(of: window.bytes), cleanEvents: eventsByLine(of: window))
        guard check.clean.events == check.cleanEvents.events,
              check.clean.summary.damage.isEmpty,
              check.clean.summary.files.count == window.fileCount
        else {
            return .failure(SetupError(description: """
                the clean window parses with \(check.clean.summary.damage.count) damage reports and \
                \(check.clean.summary.files.count) files for \(window.fileCount) diff lines
                """))
        }
        if let part = check.firstPartNotRenderingBack {
            return .failure(SetupError(description: "the clean window's \(part) doesn't render back to its bytes"))
        }
        return .success(check)
    }

    /// The events of `window` fed a line at a time.
    static func eventsByLine(of window: DiffWindow, options: ParsingOptions = .init()) -> LineEvents {
        var parser = DiffEventParser(consumer: EventRecorder(), options: options)
        let eventsBeforeLine = window.lines.map { line in
            let count = parser.consumer.events.count
            parser.consume(window.bytes[line])
            return count
        } + [parser.consumer.events.count]
        return LineEvents(events: parser.finalize().events, eventsBeforeLine: eventsBeforeLine)
    }

    /// The rules `mutation` breaks, each in a short line; empty when it
    /// keeps them all. `generator` picks the chunkings and the line cap.
    func failures(of mutation: Mutation, using generator: inout SplitMix64) -> [String] {
        let bytes = mutation.applied(to: window.bytes)
        let footprint = window.footprint(of: mutation)
        let mutated = ParseResults(of: bytes)
        // Mostly small, so most lines are split somewhere.
        let chunkSizes = (0..<16).map { _ in
            generator.chance(3, in: 4) ? generator.next(in: 1...16) : generator.next(in: 17...700)
        }
        let options = ParsingOptions(maximumLineLength: Self.lineCap(for: bytes, using: &generator))
        let capped = EventRecorder.events(in: bytes, options: options)
        let cappedChunkSizes = generator.chance(1, in: 2) ? [1] : chunkSizes.reversed()
        let newline = DiffWindow.newline
        let addedLines = mutation.replacement.count { $0 == newline }
            - window.bytes[mutation.range].count { $0 == newline }
        return Self.chunkInvariance(of: bytes, mutated, chunkSizes: chunkSizes)
            + Self.chunkInvariance(of: bytes, capped, options: options, chunkSizes: cappedChunkSizes)
            + Self.consistency(of: mutated, bytes: bytes)
            + [
                Self.eventLocality(
                    mutated.events, clean: cleanEvents, in: window, footprint: footprint, addedLines: addedLines
                ),
                cappedEventLocality(capped, options: options, footprint: footprint, addedLines: addedLines),
                summaryLocality(mutated, footprint: footprint),
                changedLinesLocality(mutated, footprint: footprint),
                modelLocality(mutated, footprint: footprint),
                damageLocality(mutated, footprint: footprint, addedLines: addedLines, bytes: bytes),
            ].compactMap(\.self)
    }

    /// Where two event streams first part ways, briefly; nil when equal.
    static func firstDifference(
        _ ours: some Collection<EventRecorder.Event>, _ expected: some Collection<EventRecorder.Event>
    ) -> String? {
        let ours = Array(ours)
        let expected = Array(expected)
        let index = zip(ours, expected).prefix { $0 == $1 }.count
        guard index < max(ours.count, expected.count) else { return nil }
        let describe = { (events: [EventRecorder.Event]) in
            index < events.count ? String(events[index].description.prefix(120)) : "the end"
        }
        return "at event \(index) of \(ours.count) vs \(expected.count): \(describe(ours)) vs \(describe(expected))"
    }
}
