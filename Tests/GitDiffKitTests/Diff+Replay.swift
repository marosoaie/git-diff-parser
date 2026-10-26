@testable import GitDiffKit

extension Diff {
    /// The model of `bytes`, fed to a parser in `chunkSize`-byte chunks
    /// with the full model's options.
    static func of(_ bytes: [UInt8], chunkSize: Int = .max) -> Diff {
        DiffEventParser.collect(Collector(), from: bytes, chunkSize: chunkSize, options: .fullModel).diff
    }

    /// The events that would build this model, in order. Damage reports
    /// are left out: the model keeps them, but not where they fell among
    /// the other events.
    var replayedEvents: [EventRecorder.Event] {
        preamble.map(Self.unrecognized) + files.flatMap(Self.events)
            + (hasNoNewlineAtEnd ? [.noNewlineAtEndOfInput] : [])
    }

    /// Each file's added and deleted line counts, as a summary reports them.
    var lineCounts: [[Int]] {
        files.map { file in
            [file.lines.count { $0.info.kind == .addition }, file.lines.count { $0.info.kind == .deletion }]
        }
    }

    private static func events(of file: DiffFile) -> [EventRecorder.Event] {
        let begin: [EventRecorder.Event] = [.beginFile(file.header, rawHeader: Array(file.rawHeader))]
        let binary = file.binaryPatchLines.map { line -> EventRecorder.Event in
            .binaryPatchLine(Array(line.content), endsWithCarriageReturn: line.endsWithCarriageReturn)
        }
        let hunks = file.hunks.flatMap { hunk in
            [.beginHunk(hunk.header, heading: Array(hunk.heading))]
                + hunk.lines.flatMap(events)
                + hunk.trailingLines.map(unrecognized)
        }
        return begin + binary + file.leadingLines.map(unrecognized) + hunks + [.endFile]
    }

    private static func events(of line: DiffLine) -> [EventRecorder.Event] {
        let marker: [EventRecorder.Event] = line.hasNoNewlineAtEnd
            ? [.noNewlineAtEndOfFile(endsWithCarriageReturn: line.noNewlineMarkerEndsWithCarriageReturn)]
            : []
        return [.line(line.info, content: Array(line.content))] + marker
    }

    private static func unrecognized(_ line: DiffTextLine) -> EventRecorder.Event {
        .unrecognizedLine(Array(line.content), endsWithCarriageReturn: line.endsWithCarriageReturn)
    }
}

extension EventRecorder {
    /// The events of `bytes` without damage reports, as `Diff.replayedEvents`
    /// gives them, with the full model's options.
    static func eventsWithoutDamage(in bytes: [UInt8]) -> [Event] {
        events(in: bytes, options: .fullModel).filter { event in
            if case .damage = event { false } else { true }
        }
    }
}
