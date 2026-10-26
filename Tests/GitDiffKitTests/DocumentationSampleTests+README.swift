import GitDiffKit
import Testing

/// The samples of the README that the articles don't share.
extension DocumentationSampleTests {
    @Test("README: quick start")
    func readmeQuickStart() {
        let changes = ChangedLines(diff: diffText)
        let paths = changes.sortedPaths   // ["README.md", "Sources/App/Greeting.swift"]
        let greeting = changes.ranges(in: "Sources/App/Greeting.swift")   // [2...3]
        let isChanged = changes.contains(line: 3, in: "Sources/App/Greeting.swift")   // true

        #expect(paths == ["README.md", "Sources/App/Greeting.swift"])
        #expect(greeting == [2...3])
        #expect(isChanged)
    }
}
