/// The line ranges a hunk's `@@ -oldStart,oldCount +newStart,newCount @@`
/// line declares, and how the line spells them.
///
/// Starts and counts are at most 2⁴⁸; a header with larger numbers is
/// rejected as damaged, so line arithmetic downstream can't overflow.
public struct HunkHeader: Sendable, Equatable {
    /// The first old-side line the hunk covers; 0 for an empty old side.
    public var oldStart: Int
    /// How many old-side lines the hunk covers.
    public var oldCount: Int
    /// The first new-side line the hunk covers; 0 for an empty new side.
    public var newStart: Int
    /// How many new-side lines the hunk covers.
    public var newCount: Int
    /// Whether the old range left its count out (`-5` for `-5,1`), as git
    /// does for one-line ranges.
    public var oldCountIsImplicit: Bool
    /// Whether the new range left its count out.
    public var newCountIsImplicit: Bool
    /// Whether the `@@` line ended in `\r\n`, as every line of a diff
    /// stored with CRLF line endings does. The `\r` is not part of the
    /// heading; this flag renders it back. Git itself never writes one: it
    /// trims trailing whitespace from the heading.
    public var endsWithCarriageReturn: Bool

    /// Creates a header from its ranges.
    public init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        oldCountIsImplicit: Bool = false,
        newCountIsImplicit: Bool = false,
        endsWithCarriageReturn: Bool = false
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.oldCountIsImplicit = oldCountIsImplicit
        self.newCountIsImplicit = newCountIsImplicit
        self.endsWithCarriageReturn = endsWithCarriageReturn
    }

    /// Upper bound for hunk starts and counts (~2.8e14). Real files are many
    /// orders of magnitude smaller; anything larger is corrupt input.
    static let maxLineNumber = 1 << 48

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@heading`,
    /// returning the header and the heading's bytes.
    static func parse(_ line: ArraySlice<UInt8>) -> (header: HunkHeader, heading: ArraySlice<UInt8>)? {
        var cursor = HunkHeaderCursor(line: line)
        guard cursor.expect(Self.opening),
              let old = cursor.range(),
              cursor.expect(Self.newSide),
              let new = cursor.range(),
              cursor.expect(Self.closing)
        else { return nil }
        let header = HunkHeader(
            oldStart: old.start,
            oldCount: old.count,
            newStart: new.start,
            newCount: new.count,
            oldCountIsImplicit: old.countIsImplicit,
            newCountIsImplicit: new.countIsImplicit
        )
        return (header, cursor.rest)
    }

    /// Parses a combined diff's `@@@ -a,b -c,d +e,f @@@` for `parents`
    /// parents (one more `@` than parents on each end), returning each
    /// parent's line count and the result's.
    static func parseCombined(_ line: ArraySlice<UInt8>, parents: Int) -> (parentCounts: [Int], newCount: Int)? {
        let marker = [UInt8](repeating: UInt8(ascii: "@"), count: parents + 1)
        var cursor = HunkHeaderCursor(line: line)
        guard cursor.expect(marker) else { return nil }
        let parentCounts = (0..<parents).compactMap { _ in
            cursor.expect(Self.combinedOldSide) ? cursor.range()?.count : nil
        }
        guard parentCounts.count == parents,
              cursor.expect(Self.newSide),
              let new = cursor.range(),
              cursor.expect([UInt8(ascii: " ")] + marker)
        else { return nil }
        return (parentCounts, new.count)
    }

    private static let opening = Array("@@ -".utf8)
    private static let combinedOldSide = Array(" -".utf8)
    private static let newSide = Array(" +".utf8)
    private static let closing = Array(" @@".utf8)
}

/// Reads a hunk header's fields left to right.
private struct HunkHeaderCursor {
    let line: ArraySlice<UInt8>
    var index: ArraySlice<UInt8>.Index

    init(line: ArraySlice<UInt8>) {
        self.line = line
        index = line.startIndex
    }

    var rest: ArraySlice<UInt8> { line[index...] }

    mutating func expect(_ text: [UInt8]) -> Bool {
        guard line[index...].starts(with: text) else { return false }
        index += text.count
        return true
    }

    struct DeclaredRange {
        var start: Int
        var count: Int
        var countIsImplicit: Bool
    }

    /// `start[,count]`; a missing count is 1.
    mutating func range() -> DeclaredRange? {
        guard let start = number() else { return nil }
        guard index < line.endIndex, line[index] == UInt8(ascii: ",") else {
            return DeclaredRange(start: start, count: 1, countIsImplicit: true)
        }
        index += 1
        return number().map { DeclaredRange(start: start, count: $0, countIsImplicit: false) }
    }

    private mutating func number() -> Int? {
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        var value = 0
        var sawDigit = false
        // A cursor rather than `prefix(while:)` + reduce: it stops at the
        // first digit past the cap, so a hostile megabyte of digits costs
        // nothing, and the cap keeps `value * 10 + 9` far from overflowing.
        while index < line.endIndex, digits.contains(line[index]) {
            value = value * 10 + Int(line[index] - UInt8(ascii: "0"))
            // Capped well below Int.max so downstream line arithmetic
            // (numbers += 1, range merging) can never overflow either.
            guard value <= HunkHeader.maxLineNumber else { return nil }
            sawDigit = true
            index += 1
        }
        return sawDigit ? value : nil
    }
}
