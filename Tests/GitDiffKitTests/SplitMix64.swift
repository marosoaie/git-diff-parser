/// A small seeded generator (SplitMix64). The same seed gives the same
/// numbers on every platform and Swift version, which the standard
/// library's `random(in:using:)` doesn't promise, so a mutation test's
/// failing seed reproduces anywhere.
struct SplitMix64 {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed))
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        let mixed = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        let remixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return remixed ^ (remixed >> 31)
    }

    /// A number in `0..<bound`; the modulo bias is negligible at the small
    /// bounds the tests use.
    mutating func next(below bound: Int) -> Int {
        precondition(bound > 0, "an empty range has no numbers")
        return Int(next() % UInt64(bound))
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + next(below: range.count)
    }

    mutating func element<Elements: RandomAccessCollection>(of elements: Elements) -> Elements.Element {
        elements[elements.index(elements.startIndex, offsetBy: next(below: elements.count))]
    }

    /// True `numerator` times in `denominator`.
    mutating func chance(_ numerator: Int, in denominator: Int) -> Bool {
        next(below: denominator) < numerator
    }
}
