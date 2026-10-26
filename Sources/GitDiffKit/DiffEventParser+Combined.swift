/// Combined diffs (`diff --cc`, `diff --combined`) are skipped (D9): their
/// hunks are only counted, so their content can't be read as headers or
/// as another file's lines.
///
/// A combined hunk line has one marker column per parent. The counting
/// rule: a line with a `-` column isn't in the result and uses up parent
/// i's budget wherever column i is `-`; any other line is in the result
/// and uses up the result's budget, plus parent i's wherever column i
/// isn't `+` (the line was there in that parent).
extension DiffEventParser {
    mutating func beginCombinedHunk(_ line: RawLine, parents: Int) {
        guard let counts = HunkHeader.parseCombined(line.bytes, parents: parents) else {
            report(.malformedHunkHeader)
            return unrecognized(line)
        }
        hunk.parentRemaining = counts.parentCounts
        // Each count is at most 2⁴⁸ and there are at most 64, so the sum
        // can't overflow.
        hunk.remainingOld = counts.parentCounts.reduce(0, +)
        hunk.remainingNew = counts.newCount
        hunk.emitsEvents = false
        hunk.reportsDamage = true
        hunk.isCombined = true
    }

    mutating func processCombinedHunkLine(_ line: RawLine) {
        let bytes = line.bytes
        if bytes.starts(with: DiffSyntax.diffPrefix) {
            return endHunkEarly(line)
        }
        if bytes.first == UInt8(ascii: "\\") {
            if !takeNoNewlineMarker(line) {
                report(.misplacedNoNewlineMarker)
            }
            return
        }
        let minus = UInt8(ascii: "-")
        let plus = UInt8(ascii: "+")
        // A line shorter than the columns (whitespace stripping) is context.
        let columns = hunk.parentRemaining.indices.map { index in
            index < bytes.count ? bytes[bytes.startIndex + index] : UInt8(ascii: " ")
        }
        let isRemoved = columns.contains(minus)
        let parents = columns.indices.filter { isRemoved ? columns[$0] == minus : columns[$0] != plus }
        guard isRemoved || hunk.remainingNew > 0, parents.allSatisfy({ hunk.parentRemaining[$0] > 0 }) else {
            return endHunkEarly(line)
        }
        parents.forEach { hunk.parentRemaining[$0] -= 1 }
        hunk.remainingOld -= parents.count
        if !isRemoved {
            hunk.remainingNew -= 1
        }
        hunk.lastContentLine = lineNumber
    }
}
