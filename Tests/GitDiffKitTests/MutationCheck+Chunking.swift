@testable import GitDiffKit

extension MutationCheck {
    /// Half the time a tiny cap, else one at a line's length, give or take
    /// a byte — preferably a CRLF line's, where a `\r` past the cap must
    /// not count as truncation.
    static func lineCap(for bytes: [UInt8], using generator: inout SplitMix64) -> Int {
        let carriageReturn = UInt8(ascii: "\r")
        let lines = bytes.split(separator: DiffWindow.newline, omittingEmptySubsequences: false)
        let crlfLines = lines.filter { $0.last == carriageReturn }
        let candidates = !crlfLines.isEmpty && generator.chance(1, in: 2) ? crlfLines : lines
        guard generator.chance(1, in: 2), !candidates.isEmpty else {
            return generator.element(of: [0, 1, 2, 7])
        }
        let line = generator.element(of: candidates)
        let length = line.last == carriageReturn ? line.count - 1 : line.count
        return max(0, length + generator.next(in: -1...1))
    }

    /// Events in 1-byte chunks, and every result in `chunkSizes`' chunks,
    /// against the whole input's.
    static func chunkInvariance(of bytes: [UInt8], _ whole: ParseResults, chunkSizes: [Int]) -> [String] {
        let byteByByte = firstDifference(EventRecorder.events(in: bytes, chunkSize: 1), whole.events)
            .map { "events in 1-byte chunks differ from the whole input's: \($0)" }
        let chunked = ParseResults(of: bytes, chunkSizes: chunkSizes).differences(from: whole).map {
            "\($0) differs at chunk sizes \(chunkSizes)"
        }
        return [byteByByte].compactMap(\.self) + chunked
    }

    /// Events under a line cap in `chunkSizes`' chunks against the whole
    /// input's.
    static func chunkInvariance(
        of bytes: [UInt8], _ whole: [EventRecorder.Event], options: ParsingOptions, chunkSizes: [Int]
    ) -> [String] {
        let chunked = DiffEventParser.collect(EventRecorder(), from: bytes, chunkSizes: chunkSizes, options: options)
        return [firstDifference(chunked.events, whole).map {
            "events with a \(options.maximumLineLength)-byte line cap differ at chunk sizes \(chunkSizes): \($0)"
        }].compactMap(\.self)
    }

    /// The collectors agree with the events and with each other: the model
    /// replays as the events, and the summary and `ChangedLines` are what
    /// the model's files say.
    static func consistency(of results: ParseResults, bytes: [UInt8]) -> [String] {
        let damage = EventRecorder.damage(in: results.events)
        // The model's line cap is 64 MiB, the events' 1 MiB: a longer line
        // (piled edits can join a window into one) needs the model's cap.
        let longestLine = bytes.split(separator: DiffWindow.newline, omittingEmptySubsequences: false)
            .lazy.map(\.count).max() ?? 0
        let modelEvents = longestLine > ParsingOptions().maximumLineLength
            ? EventRecorder.events(in: bytes, options: .fullModel)
            : results.events
        let replayed = firstDifference(
            results.diff.replayedEvents,
            modelEvents.filter { if case .damage = $0 { false } else { true } }
        ).map { "Diff doesn't replay as the events: \($0)" }
        let files = zip(results.diff.files, results.diff.lineCounts).map { file, counts in
            DiffSummary.File(header: file.header, addedLineCount: counts[0], deletedLineCount: counts[1])
        }
        let additions = results.diff.files.reduce(into: [String: LineRangeSet]()) { lines, file in
            guard let path = file.header.newPath?.string else { return }
            file.lines.filter { $0.info.kind == .addition }.compactMap(\.info.newNumber).forEach {
                lines[path, default: LineRangeSet()].insert($0)
            }
        }
        return [
            replayed,
            results.diff.damage == EventRecorder.damage(in: modelEvents) && results.summary.damage == damage
                ? nil : "the collectors' damage differs from the events'",
            results.summary.files == files ? nil : "DiffSummary's files differ from Diff's",
            results.changedLines == ChangedLines(files: additions) ? nil : "ChangedLines differs from Diff's additions",
        ].compactMap(\.self)
    }
}

extension MutationCheck {
    /// The rules that hold for any input, whatever its damage: no trap,
    /// results that don't depend on chunking, and collectors that agree
    /// with the events. For a pile of edits, where the footprint of each
    /// no longer says which files should come out clean.
    static func failures(ofDamaged bytes: [UInt8], using generator: inout SplitMix64) -> [String] {
        let whole = ParseResults(of: bytes)
        let chunkSizes = (0..<16).map { _ in generator.next(in: 1...32) }
        let options = ParsingOptions(maximumLineLength: lineCap(for: bytes, using: &generator))
        let capped = EventRecorder.events(in: bytes, options: options)
        return chunkInvariance(of: bytes, whole, chunkSizes: chunkSizes)
            + chunkInvariance(of: bytes, capped, options: options, chunkSizes: [1])
            + consistency(of: whole, bytes: bytes)
    }
}
