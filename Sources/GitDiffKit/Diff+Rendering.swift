extension Diff {
    /// Writes the diff back as unified diff text, handing it to `write` in
    /// chunks of about 64 KiB, so the text never has to fit in memory.
    ///
    ///     try diff.render { chunk in try handle.write(contentsOf: chunk) }
    ///
    /// For a diff parsed from `git diff`, `git show`, `git log -p`, or
    /// `git format-patch` output, or from plain `diff -u`, the text is the
    /// input byte for byte, and git applies it as it would the input. Files
    /// come out in input order, each as its raw header, its binary patch
    /// lines, its leading lines, then its hunks, each followed by its
    /// trailing lines; every `\r`, bare context line, and missing final
    /// newline is kept. The text differs from the input only where the
    /// model doesn't keep it:
    ///
    /// - a combined diff (`diff --cc`) renders as its header alone, since
    ///   its hunks are skipped;
    /// - damaged input renders as the model holds it: an abandoned file is
    ///   missing, and a line cut at the line cap stays cut;
    /// - a localized `\ No newline at end of file` comes out in English;
    /// - hunk header numbers lose leading zeros, which git never writes
    ///   (`-03` comes out as `-3`; `-3` and `-3,1` stay as they were).
    ///
    /// A file's header comes from its `rawHeader` alone, never from
    /// `header`, so changing `header` changes nothing here, and a file
    /// built without a raw header renders with none. To render some of the
    /// files, render a diff of them: `Diff(files: diff.files.filter(…))`.
    ///
    /// Each chunk is a slice of a buffer the renderer reuses; keeping one
    /// past the call costs a copy of the buffer.
    public func render(_ write: (ArraySlice<UInt8>) throws -> Void) rethrows {
        try render(chunkSize: DiffTextWriter.defaultChunkSize, write)
    }

    func render(chunkSize: Int, _ write: (ArraySlice<UInt8>) throws -> Void) rethrows {
        var writer = DiffTextWriter(chunkSize: chunkSize)
        try writer.append(self, flushingTo: write)
        if !writer.text.isEmpty {
            try write(writer.text[...])
        }
    }
}

extension Array where Element == UInt8 {
    /// Creates the unified diff text of `diff`, as `Diff.render(_:)` writes
    /// it: for a diff parsed from git's output, the input byte for byte.
    ///
    ///     let text = [UInt8](rendering: Diff(diff: input))   // == input
    ///
    /// The whole text is held on top of the model (for the kernel's 74 MB
    /// diff, 381 MB at the peak against the model's 188 MB); to write a
    /// large diff out, stream it with `render(_:)` instead.
    public init(rendering diff: Diff) {
        var writer = DiffTextWriter(chunkSize: .max)
        writer.append(diff) { _ in }
        self = writer.text
    }
}
