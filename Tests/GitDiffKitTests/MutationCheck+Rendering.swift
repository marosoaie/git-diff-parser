@testable import GitDiffKit

extension MutationCheck {
    /// An input that parses without damage, however mangled, renders to
    /// text that parses back to the same model, up to its first combined
    /// file: the renderer writes what the parser kept. Damage can change
    /// how a file reads back (a misplaced `\ No newline at end of file`
    /// that ended a header is dropped, so the lines after it join the
    /// header), and so can a combined file, whose hunks aren't kept though
    /// they set its parent count and end its header.
    static func renderingRoundTrip(of diff: Diff) -> String? {
        guard diff.damage.isEmpty else { return nil }
        let files = diff.files.prefix { file in
            if case .combined = file.header.format { false } else { true }
        }
        let kept = Diff(
            preamble: diff.preamble,
            files: Array(files),
            hasNoNewlineAtEnd: files.count == diff.files.count && diff.hasNoNewlineAtEnd
        )
        return firstDifference(Diff(diff: [UInt8](rendering: kept)).replayedEvents, kept.replayedEvents)
            .map { "the model's rendering parses to a different model: \($0)" }
    }

    /// The first part of the clean window, its preamble or a file, whose
    /// model doesn't render back to its own bytes, as git's output must;
    /// nil when all do. Combined files are skipped: the model keeps none of
    /// their hunks.
    var firstPartNotRenderingBack: String? {
        let bounds = [0] + window.fileStarts + [window.bytes.count]
        let parts = zip(bounds, bounds.dropFirst()).map { window.bytes[$0..<$1] }
        let models = [Diff(preamble: clean.diff.preamble)] + clean.diff.files.map { Diff(files: [$0]) }
        return parts.indices.first { index in
            if case .combined? = models[index].files.first?.header.format { return false }
            return !parts[index].elementsEqual([UInt8](rendering: models[index]))
        }.map { $0 == 0 ? "preamble" : "file \($0)" }
    }
}
