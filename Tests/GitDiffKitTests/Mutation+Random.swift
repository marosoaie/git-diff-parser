extension Mutation {
    /// A seeded edit of `window`, the same for the same generator state:
    /// byte noise anywhere (replaced, inserted, deleted, the input cut
    /// short), and structural edits of the lines that steer the parser —
    /// duplicated, dropped, swapped, or copied lines (header and hunk lines
    /// half the time), a line repeated past the header bound, changed hunk
    /// counts and `@` runs, a file switched to another format, a line of
    /// diff syntax inserted, replaced line markers, and changed line endings.
    static func random(in window: DiffWindow, using generator: inout SplitMix64) -> Mutation {
        let kind = generator.element(of: Kind.allCases)
        let mutation = switch kind {
        case .byteReplaced, .bytesInserted, .bytesDeleted, .truncated:
            byteEdit(kind, in: window, using: &generator)
        case .carriageReturnAdded, .newlineRemoved:
            lineEndingEdit(kind, in: window, using: &generator)
        case .linesDuplicated, .lineRepeated, .linesDropped, .linesSwapped, .lineCopied:
            lineEdit(kind, in: window, using: &generator)
        case .hunkCountChanged:
            hunkCountChanged(in: window, using: &generator)
        case .atSignsChanged, .markerReplaced, .diffLineFormatChanged, .syntaxLineInserted:
            syntaxEdit(kind, in: window, using: &generator)
        }
        // Nil when the window has nothing the kind can edit.
        return mutation ?? random(in: window, using: &generator)
    }

    private static func byteEdit(_ kind: Kind, in window: DiffWindow, using generator: inout SplitMix64) -> Mutation? {
        let count = window.bytes.count
        switch kind {
        case .byteReplaced:
            let offset = generator.next(below: count)
            return Mutation(kind: kind, range: offset..<(offset + 1), replacement: [randomByte(using: &generator)])
        case .bytesInserted:
            let offset = generator.next(in: 0...count)
            let inserted = (0..<generator.next(in: 1...4)).map { _ in randomByte(using: &generator) }
            return Mutation(kind: kind, range: offset..<offset, replacement: inserted)
        case .bytesDeleted:
            let offset = generator.next(below: count)
            let end = min(count, offset + generator.next(in: 1...8))
            return Mutation(kind: kind, range: offset..<end, replacement: [])
        case .truncated:
            return Mutation(kind: kind, range: generator.next(below: count)..<count, replacement: [])
        default:
            return nil
        }
    }

    private static func lineEndingEdit(
        _ kind: Kind, in window: DiffWindow, using generator: inout SplitMix64
    ) -> Mutation? {
        let newlines = window.lines.map { $0.upperBound - 1 }.filter { window.bytes[$0] == DiffWindow.newline }
        guard !newlines.isEmpty else { return nil }
        let newline = generator.element(of: newlines)
        return kind == .newlineRemoved
            ? Mutation(kind: kind, range: newline..<(newline + 1), replacement: [])
            : Mutation(kind: kind, range: newline..<newline, replacement: [UInt8(ascii: "\r")])
    }

    private static func lineEdit(_ kind: Kind, in window: DiffWindow, using generator: inout SplitMix64) -> Mutation? {
        let bytes = window.bytes
        switch kind {
        case .linesDuplicated:
            let run = lineRun(in: window, using: &generator)
            return Mutation(kind: kind, range: run.upperBound..<run.upperBound, replacement: Array(bytes[run]))
        case .lineRepeated:
            // Around the 64-line header bound.
            let line = window.lines[structuralLine(in: window, using: &generator)]
            let copies = Array(repeating: bytes[line], count: generator.next(in: 60...70)).flatMap(\.self)
            return Mutation(kind: kind, range: line.upperBound..<line.upperBound, replacement: copies)
        case .linesDropped:
            return Mutation(kind: kind, range: lineRun(in: window, using: &generator), replacement: [])
        case .linesSwapped:
            let first = window.lines[structuralLine(in: window, using: &generator)]
            guard first.upperBound < bytes.count else { return nil }
            let second = window.lines[window.lineIndex(startingAt: first.upperBound)]
            return Mutation(
                kind: kind, range: first.lowerBound..<second.upperBound,
                replacement: Array(bytes[second]) + Array(bytes[first])
            )
        case .lineCopied:
            let source = Array(bytes[window.lines[structuralLine(in: window, using: &generator)]])
            let line = source.last == DiffWindow.newline ? source : source + [DiffWindow.newline]
            let offset = generator.element(of: window.lineStarts)
            return Mutation(kind: kind, range: offset..<offset, replacement: line)
        default:
            return nil
        }
    }

    private static func syntaxEdit(
        _ kind: Kind, in window: DiffWindow, using generator: inout SplitMix64
    ) -> Mutation? {
        let bytes = window.bytes
        switch kind {
        case .atSignsChanged:
            // A combined diff's parent count, around its cap of 64.
            let hunkLines = window.lines.filter { bytes[$0].starts(with: Array("@@".utf8)) }
            guard !hunkLines.isEmpty else { return nil }
            let line = generator.element(of: hunkLines)
            let run = line.lowerBound..<(line.first { bytes[$0] != UInt8(ascii: "@") } ?? line.upperBound)
            let count = generator.element(of: [1, 2, 3, 4, 64, 65, 66, 300])
            return Mutation(kind: kind, range: run, replacement: Array(repeating: UInt8(ascii: "@"), count: count))
        case .markerReplaced:
            let line = generator.element(of: window.lines)
            let marker = generator.element(of: Array(" +-@\\d\t\n".utf8))
            return Mutation(kind: kind, range: line.lowerBound..<(line.lowerBound + 1), replacement: [marker])
        case .diffLineFormatChanged:
            // A `diff --git ` line's prefix, so the file's headers and hunks
            // are read as another format's.
            let prefix = Array("diff --git ".utf8)
            let gitLines = window.lines.filter { bytes[$0].starts(with: prefix) }
            guard !gitLines.isEmpty else { return nil }
            let start = generator.element(of: gitLines).lowerBound
            let format = generator.element(of: ["diff --cc ", "diff --combined ", "diff -u ", "diff ", "diff --git"])
            return Mutation(kind: kind, range: start..<(start + prefix.count), replacement: Array(format.utf8))
        case .syntaxLineInserted:
            let offset = generator.element(of: window.lineStarts)
            let line = generator.element(of: syntaxLines)
            return Mutation(kind: kind, range: offset..<offset, replacement: Array("\(line)\n".utf8))
        default:
            return nil
        }
    }

    /// Lines the parser gives meaning to, most of which the real fixtures
    /// lack.
    private static let syntaxLines = [
        "GIT binary patch", "literal 0", "literal 12", "delta 7", "zcmV?d00001", "",
        "Binary files a/x and b/x differ", "Files a/x and b/x differ", "\\ No newline at end of file",
        "@@ -1 +1 @@", "@@ -0,0 +1,3 @@ heading", "@@@ -1 -1 +1 @@@", "@@@@ -1,2 -1 -1 +1,2 @@@@",
        "--- a/x", "+++ b/x", "--- /dev/null", "+++ /dev/null", "rename from x", "rename to y",
        "copy from x", "copy to y", "similarity index 50%", "dissimilarity index 101%", "old mode 100644",
        "new mode 100755", "new file mode 100644", "deleted file mode 100644", "index 0000000..1111111 100644",
        "index 1111111,2222222..3333333", "mode 100644,100644..100755", "diff --git a/x b/x", "diff --cc x",
        "diff -u a/x b/x", "Only in a: x", "commit 0123456789abcdef", "--- ",
    ]

    /// `bytes` with two to six more random edits, each made on the last
    /// one's result.
    static func piled(onto bytes: [UInt8], using generator: inout SplitMix64) -> [UInt8] {
        (0..<generator.next(in: 2...6)).reduce(bytes) { bytes, _ in
            bytes.isEmpty ? bytes : random(in: DiffWindow(bytes), using: &generator).applied(to: bytes)
        }
    }

    /// Half the time a byte the parser branches on, else any byte.
    private static func randomByte(using generator: inout SplitMix64) -> UInt8 {
        generator.chance(1, in: 2)
            ? generator.element(of: syntaxBytes)
            : UInt8(truncatingIfNeeded: generator.next())
    }

    private static let syntaxBytes = Array("\n\r\t \"\\+-@,.:/0129adi".utf8) + [0x00, 0x80, 0xC3, 0xFF]

    /// One to three lines from a line `structuralLine` picks.
    private static func lineRun(in window: DiffWindow, using generator: inout SplitMix64) -> Range<Int> {
        let first = structuralLine(in: window, using: &generator)
        let last = min(window.lines.count, first + generator.next(in: 1...3))
        return window.lineStarts[first]..<window.lineStarts[last]
    }

    /// A line index: half the time one of the lines that steer the parser
    /// (file headers, hunk headers, markers), else any line.
    private static func structuralLine(in window: DiffWindow, using generator: inout SplitMix64) -> Int {
        let structural = window.lines.indices.filter { index in
            let line = window.bytes[window.lines[index]]
            return structuralPrefixes.contains { line.starts(with: $0) }
        }
        return generator.chance(1, in: 2) && !structural.isEmpty
            ? generator.element(of: structural)
            : generator.next(below: window.lines.count)
    }

    private static let structuralPrefixes = [
        "diff ", "index ", "--- ", "+++ ", "@@", "new file mode ", "deleted file mode ", "old mode ", "new mode ",
        "similarity index ", "dissimilarity index ", "rename ", "copy ", "Binary files ", "GIT binary patch",
        "literal ", "delta ", "\\ ", "mode ",
    ].map { Array($0.utf8) }

    /// One number of a `@@` line replaced: nudged, zeroed, doubled, or
    /// pushed to and past the parser's 2⁴⁸ cap. Nil if no line has one.
    private static func hunkCountChanged(in window: DiffWindow, using generator: inout SplitMix64) -> Mutation? {
        let hunkLines = window.lines.filter { window.bytes[$0].starts(with: Array("@@".utf8)) }
        guard !hunkLines.isEmpty else { return nil }
        let line = generator.element(of: hunkLines)
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        let numbers = line.filter { offset in
            digits.contains(window.bytes[offset])
                && (offset == line.lowerBound || !digits.contains(window.bytes[offset - 1]))
        }.map { start in
            start..<(line[start...].first { !digits.contains(window.bytes[$0]) } ?? line.upperBound)
        }
        guard !numbers.isEmpty else { return nil }
        let number = generator.element(of: numbers)
        // Saturates instead of overflowing; real counts are far smaller.
        let value = window.bytes[number].reduce(0) { partial, digit in
            partial > 1 << 50 ? partial : partial * 10 + Int(digit - UInt8(ascii: "0"))
        }
        let replacement = generator.element(of: [
            "\(value + 1)", "\(max(0, value - 1))", "0", "\(value * 2)", "\(value + 1000)",
            "\(1 << 48)", "\((1 << 48) + 1)", "\(Int.max)", "99999999999999999999", "",
        ])
        return Mutation(kind: .hunkCountChanged, range: number, replacement: Array(replacement.utf8))
    }
}
