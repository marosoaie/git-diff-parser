/// The full model of a diff: every file with its header, hunks, and line
/// content, plus whatever text came before the first file.
///
///     let diff = Diff(diff: diffText)
///     for file in diff.files {
///         for line in file.lines where line.info.kind == .addition {
///             let text = String(decoding: line.content, as: UTF8.self)
///             print(file.header.newPath?.string ?? "", line.info.newNumber ?? 0, text)
///         }
///     }
///
/// **Memory grows with the diff's content**: the model keeps every byte of
/// it, packed per file, and peaks at about 2.5× the diff's size (187 MB
/// for the Linux kernel's 74 MB release diff, 1.1 GB for six copies of
/// it). For huge diffs, prefer a `DiffSummary`, a `ChangedLines`, or a
/// `DiffEventConsumer` of your own, whose memory doesn't grow with content.
///
/// Its entry points — `Diff(diff:)` and `DiffEventParser<Diff.Collector>()`
/// — raise the parser's line cap to 64 MiB (`ParsingOptions.fullModel`),
/// so content is kept whole up to that length. A file abandoned as damaged
/// is missing, and its `DamageReport` is in `damage`. Combined diffs of
/// merges are kept with format `.combined`, their raw header and no hunks
/// (see `FileHeader.Format.combined`).
public struct Diff: Sendable, Equatable {
    /// Lines before the first file, such as a `git show` commit header or
    /// a mail's headers. Later unrecognized lines belong to the file they
    /// appear in, as its `leadingLines` or a hunk's `trailingLines`.
    public var preamble: DiffFile.TextLines
    /// The diff's files, in input order.
    public var files: [DiffFile]
    /// Every damage report the parser made, in input order.
    public var damage: [DamageReport]

    /// Creates a diff from its parts.
    public init(preamble: DiffFile.TextLines = [], files: [DiffFile] = [], damage: [DamageReport] = []) {
        self.preamble = preamble
        self.files = files
        self.damage = damage
    }

    /// Parses a complete diff held in memory into the full model, with the
    /// line cap at 64 MiB. For large inputs, prefer streaming chunks
    /// through a `DiffEventParser<Diff.Collector>`.
    public init(diff: String) {
        var parser = DiffEventParser<Collector>()
        parser.consume(diff)
        self = parser.finalize().diff
    }

    /// Parses a complete diff held in memory as bytes, which needn't be
    /// valid UTF-8, into the full model, with the line cap at 64 MiB.
    public init(diff: [UInt8]) {
        var parser = DiffEventParser<Collector>()
        parser.consume(diff)
        self = parser.finalize().diff
    }
}
