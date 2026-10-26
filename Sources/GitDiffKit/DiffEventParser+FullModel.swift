extension DiffEventParser where Consumer == Diff.Collector {
    /// Creates a parser that collects the full model, with the line cap
    /// raised to 64 MiB (`ParsingOptions.fullModel`) by default.
    ///
    ///     var parser = DiffEventParser<Diff.Collector>()
    ///     while let chunk = readSomeBytes() { parser.consume(chunk) }
    ///     let diff = parser.finalize().diff
    ///
    /// Memory grows with the diff's content; see `Diff`.
    public init(options: ParsingOptions = .fullModel) {
        self.init(consumer: Diff.Collector(), options: options)
    }
}
