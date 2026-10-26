@testable import GitDiffKit

extension MutationCheck {
    /// How many of the window's files come before and after the footprint.
    private func untouchedCounts(_ footprint: DiffWindow.Footprint) -> (before: Int, after: Int) {
        (max(0, footprint.files.lowerBound - 1), window.fileCount - footprint.files.upperBound)
    }

    /// The events before the first changed line, and after the next intact
    /// `diff ` line's, are the clean parse's; damage reports after the edit
    /// shift by the lines it added.
    static func eventLocality(
        _ events: [EventRecorder.Event],
        clean: LineEvents,
        in window: DiffWindow,
        footprint: DiffWindow.Footprint,
        addedLines: Int
    ) -> String? {
        let before = clean.eventsBeforeLine[window.lineIndex(startingAt: footprint.lines.lowerBound)]
        // The intact `diff ` line's own events close whatever the damage
        // left open, so they're left out.
        let after = footprint.files.upperBound < window.fileCount
            ? clean.eventsBeforeLine[window.lineIndex(startingAt: window.fileStarts[footprint.files.upperBound]) + 1]
            : clean.events.count
        let prefix = clean.events[..<before]
        let suffix = clean.events[after...]
        guard events.count >= prefix.count + suffix.count else {
            return "\(events.count) events, fewer than the \(prefix.count + suffix.count) outside the footprint"
        }
        if let difference = firstDifference(events.prefix(prefix.count), prefix) {
            return "events before the edit differ: \(difference)"
        }
        let shifted = events.suffix(suffix.count).map { event -> EventRecorder.Event in
            guard case .damage(var report) = event else { return event }
            report.lineNumber -= addedLines
            return .damage(report)
        }
        return firstDifference(shifted, suffix).map { "events after the footprint differ: \($0)" }
    }

    /// `eventLocality` under the line cap, which damages the clean parse
    /// too. Below 5 bytes, a `diff ` line is cut short of its prefix and
    /// resets nothing, so the rule doesn't apply.
    func cappedEventLocality(
        _ events: [EventRecorder.Event], options: ParsingOptions, footprint: DiffWindow.Footprint, addedLines: Int
    ) -> String? {
        guard options.maximumLineLength >= DiffWindow.diffPrefix.count else { return nil }
        return Self.eventLocality(
            events, clean: Self.eventsByLine(of: window, options: options),
            in: window, footprint: footprint, addedLines: addedLines
        ).map { "with a \(options.maximumLineLength)-byte line cap, \($0)" }
    }

    func summaryLocality(_ mutated: ParseResults, footprint: DiffWindow.Footprint) -> String? {
        let (before, after) = untouchedCounts(footprint)
        let files = mutated.summary.files
        guard files.count >= before + after,
              files.prefix(before).elementsEqual(clean.summary.files.prefix(before)),
              files.suffix(after).elementsEqual(clean.summary.files.suffix(after))
        else {
            return "DiffSummary's \(files.count) files don't keep the \(before) before and \(after) after the footprint"
        }
        return nil
    }

    func changedLinesLocality(_ mutated: ParseResults, footprint: DiffWindow.Footprint) -> String? {
        let (before, after) = untouchedCounts(footprint)
        let cleanFiles = clean.summary.files
        let untouched = cleanFiles.prefix(before) + cleanFiles.suffix(after)
        // A damaged file may come out under any path, even an untouched
        // file's, and `ChangedLines` would merge the two.
        let damaged = cleanFiles.dropFirst(before).dropLast(after)
            + mutated.summary.files.dropFirst(before).dropLast(after)
        let excluded = Set(damaged.compactMap { $0.header.newPath?.string })
        let differing = Set(untouched.compactMap { $0.header.newPath?.string })
            .subtracting(excluded)
            .filter { mutated.changedLines.files[$0] != clean.changedLines.files[$0] }
            .sorted()
        return differing.isEmpty ? nil : "ChangedLines differs for untouched \(differing.prefix(3))"
    }

    func modelLocality(_ mutated: ParseResults, footprint: DiffWindow.Footprint) -> String? {
        let (before, after) = untouchedCounts(footprint)
        let files = mutated.diff.files
        if footprint.files.lowerBound > 0, mutated.diff.preamble != clean.diff.preamble {
            return "Diff's preamble changed, though the footprint starts at file \(footprint.files.lowerBound)"
        }
        guard files.count >= before + after,
              files.prefix(before).elementsEqual(clean.diff.files.prefix(before)),
              files.suffix(after).elementsEqual(clean.diff.files.suffix(after))
        else {
            return "Diff's \(files.count) files don't keep the \(before) before and \(after) after the footprint"
        }
        return nil
    }

    /// Damage is reported between the first changed line and the next
    /// intact `diff ` line, or one past the end.
    func damageLocality(
        _ mutated: ParseResults, footprint: DiffWindow.Footprint, addedLines: Int, bytes: [UInt8]
    ) -> String? {
        let newline = DiffWindow.newline
        let firstLine = window.lineIndex(startingAt: footprint.lines.lowerBound) + 1
        let lineCount = bytes.count { $0 == newline } + (bytes.last.map { $0 != newline } == true ? 1 : 0)
        let lastLine = footprint.files.upperBound < window.fileCount
            ? window.lineIndex(startingAt: window.fileStarts[footprint.files.upperBound]) + 1 + addedLines
            : lineCount + 1
        let stray = mutated.summary.damage.filter { !(firstLine...lastLine).contains($0.lineNumber) }
        return stray.isEmpty ? nil : """
            damage outside lines \(firstLine)...\(lastLine): \
            \(stray.prefix(3).map { "\($0.reason) at \($0.lineNumber)" })
            """
    }
}
