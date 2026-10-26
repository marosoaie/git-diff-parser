import Foundation
import Testing
@testable import GitDiffKit

/// Seeded mutations of clean diffs — byte noise and structural edits (see
/// `Mutation.random(in:using:)`) — checked against `MutationCheck`'s rules:
/// no trap, results that don't depend on chunking, collectors that agree
/// with the events, and the files outside the edit's footprint exactly as
/// in the clean parse. Odd seeds then pile up to six more edits on top and
/// check the rules that hold for any input.
///
/// Each seed picks a window and an edit, the same on every platform. A
/// failure names its seed; to rerun some, set
/// `GIT_DIFF_PARSER_MUTATION_SEEDS` to a seed or a range (`0..<100000`).
/// A trap kills the run before it can say which seed did it: set
/// `GIT_DIFF_PARSER_MUTATION_TRACE=1` to print each seed to stderr before
/// it runs.
@Suite("Mutated diffs", .timeLimit(.minutes(10)))
struct MutationTests {
    /// Structures the real fixtures lack, as one clean diff: a commit
    /// preamble, every status, `Binary files`, a `GIT binary patch`,
    /// combined diffs of two and three parents, a plain `diff -u` file,
    /// a quoted path, CRLF, commit text between files, and a missing
    /// newline at the end of a file.
    static let corpus = DiffSummaryTests.statuses + DiffTests.binaryPatch + combined + """
        diff -u old/f.txt new/f.txt

        """ + DiffTests.plain + quoted + DiffTests.crlf + DiffTests.logWithCommits

    static let combined = """
        diff --cc merged.txt
        index 1111111,2222222..3333333
        --- a/merged.txt
        +++ b/merged.txt
        @@@ -1,2 -1,2 +1,2 @@@
          same
        - ours
         -theirs
        ++both
        diff --cc oct.txt
        index 1111111,2222222,3333333..4444444
        --- a/oct.txt
        +++ b/oct.txt
        @@@@ -1 -1 -1 +1 @@@@
           same

        """

    static let quoted = #"""
        diff --git "a/sp\303\266cial.swift" "b/sp\303\266cial.swift"
        --- "a/sp\303\266cial.swift"
        +++ "b/sp\303\266cial.swift"
        @@ -1,2 +1,4 @@
         first
        +++ plus-prefixed content
        +@@ not a hunk
         last

        """#

    @Test("the corpus parses clean, one file per diff line")
    func corpusIsClean() throws {
        let window = DiffWindow(Array(Self.corpus.utf8))
        #expect(window.fileCount == 16)
        _ = try MutationCheck.make(window).get()
    }

    @Test("mutations of the corpus keep damage local and don't depend on chunking")
    func mutatedCorpus() throws {
        let check = try MutationCheck.make(DiffWindow(Array(Self.corpus.utf8))).get()
        Self.run("corpus", seeds: Self.seeds(default: 0..<200)) { _ in .success(check) }
    }

    @Test(
        "mutations of real diffs keep damage local and don't depend on chunking",
        .enabled(if: ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_SKIP_NETWORK_TESTS"] == nil),
        arguments: RealWorldFixture.allCases
    )
    func mutatedRealDiffs(fixture: RealWorldFixture) async throws {
        let url = try await RealWorldFixtureStore.localDiffURL(for: fixture)
        let index = DiffFileIndex(data: try Data(contentsOf: url))
        Self.run(fixture.rawValue, seeds: Self.seeds(default: 0..<80)) { generator in
            MutationCheck.make(index.window(maximumFiles: 6, maximumBytes: 16 << 10, using: &generator))
        }
    }

    // MARK: Running seeds

    /// Consecutive seeds share a window, so its clean parse serves several
    /// mutations: seed `s` mutates window `s / 4`.
    private static let mutationsPerWindow = 4

    /// Runs one mutation per seed and records the first few failures, each
    /// with its seed.
    private static func run(
        _ name: String,
        seeds: Range<Int>,
        makeCheck: @escaping (inout SplitMix64) -> Result<MutationCheck, MutationCheck.SetupError>
    ) {
        let trace = ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_MUTATION_TRACE"] != nil
        let perWindow = mutationsPerWindow
        // A stride, not a range: over a collection, the lazy `flatMap` would
        // run windows again and again to find its indices.
        let windowCount = (seeds.upperBound + perWindow - 1) / perWindow
        let windows = stride(from: seeds.lowerBound / perWindow, to: windowCount, by: 1)
        let failures = windows.lazy.flatMap { window -> [String] in
            // Seeded negative, so a window's numbers aren't any mutation's.
            var windowGenerator = SplitMix64(seed: -1 - window)
            let made = makeCheck(&windowGenerator)
            return ((window * perWindow)..<((window + 1) * perWindow)).clamped(to: seeds).compactMap { seed in
                if trace {
                    FileHandle.standardError.write(Data("\(name) seed \(seed)\n".utf8))
                }
                switch made {
                case .failure(let error):
                    return "\(name) seed \(seed): \(error)"
                case .success(let check):
                    var generator = SplitMix64(seed: seed)
                    let mutation = Mutation.random(in: check.window, using: &generator)
                    let failures = check.failures(of: mutation, using: &generator)
                    // Odd seeds then pile more edits on top.
                    let pileFailures = seed.isMultiple(of: 2) ? [] : MutationCheck.failures(
                        ofDamaged: Mutation.piled(onto: mutation.applied(to: check.window.bytes), using: &generator),
                        using: &generator
                    ).map { "with more edits piled on, \($0)" }
                    guard !(failures + pileFailures).isEmpty else { return nil }
                    return """
                        \(name) seed \(seed) (GIT_DIFF_PARSER_MUTATION_SEEDS=\(seed)), \(mutation): \
                        \((failures + pileFailures).joined(separator: "; "))
                        """
                }
            }
        }
        Array(failures.prefix(5)).forEach { Issue.record(Comment(rawValue: $0)) }
    }

    /// The seeds `GIT_DIFF_PARSER_MUTATION_SEEDS` names — one, or a range
    /// spelled `a..<b` or `a...b`, none negative — else `defaultSeeds`.
    private static func seeds(default defaultSeeds: Range<Int>) -> Range<Int> {
        guard let text = ProcessInfo.processInfo.environment["GIT_DIFF_PARSER_MUTATION_SEEDS"] else {
            return defaultSeeds
        }
        let range = ["..<", "..."].lazy.compactMap { separator -> Range<Int>? in
            let parts = text.components(separatedBy: separator)
            guard parts.count == 2, let lower = Int(parts[0]), let upper = Int(parts[1]) else { return nil }
            let end = separator == "..<" ? upper : upper + 1
            return 0 <= lower && lower < end ? lower..<end : nil
        }.first
        return range ?? Int(text).flatMap { $0 >= 0 ? $0..<($0 + 1) : nil } ?? defaultSeeds
    }
}
