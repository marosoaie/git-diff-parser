import Foundation
import Testing
@testable import BuildLogKit

@Suite("SonarReportParser")
struct SonarReportParserTests {
    static let report = """
    {
      "total": 5,
      "issues": [
        {
          "key": "a1",
          "rule": "swift:S1481",
          "severity": "MINOR",
          "component": "my-org:my-project:Sources/App/Foo.swift",
          "line": 42,
          "textRange": { "startLine": 42, "endLine": 42, "startOffset": 8, "endOffset": 14 },
          "message": "Remove this unused variable"
        },
        {
          "key": "a2",
          "rule": "swift:S2068",
          "severity": "BLOCKER",
          "component": "my-org:my-project:Sources/App/Secrets.swift",
          "line": 7,
          "message": "Review this hardcoded credential"
        },
        {
          "key": "a3",
          "rule": "swift:S1135",
          "severity": "INFO",
          "component": "my-org:my-project:Sources/App/Foo.swift",
          "line": 3,
          "message": "Complete the task associated to this TODO"
        },
        {
          "key": "file-level",
          "rule": "swift:S104",
          "severity": "MAJOR",
          "component": "my-org:my-project:Sources/App/Huge.swift",
          "message": "File has too many lines"
        },
        {
          "key": "already-fixed",
          "rule": "swift:S1481",
          "severity": "MAJOR",
          "component": "my-org:my-project:Sources/App/Foo.swift",
          "line": 99,
          "resolution": "FIXED",
          "message": "Remove this unused variable"
        }
      ]
    }
    """

    @Test("maps issues to diagnostics: path, line, column, severity, rule")
    func mapsIssues() {
        let diagnostics = SonarReportParser.diagnostics(in: Self.report)
        #expect(diagnostics == [
            Diagnostic(
                path: "Sources/App/Foo.swift", line: 42, column: 9,
                severity: .warning, message: "Remove this unused variable",
                rule: "swift:S1481"
            ),
            Diagnostic(
                path: "Sources/App/Secrets.swift", line: 7,
                severity: .error, message: "Review this hardcoded credential",
                rule: "swift:S2068"
            ),
            Diagnostic(
                path: "Sources/App/Foo.swift", line: 3,
                severity: .note, message: "Complete the task associated to this TODO",
                rule: "swift:S1135"
            ),
        ])
    }

    @Test("file-level and resolved issues are skipped")
    func skipsUnmatchable() {
        let paths = SonarReportParser.diagnostics(in: Self.report).map(\.path)
        #expect(!paths.contains("Sources/App/Huge.swift"))
        #expect(!SonarReportParser.diagnostics(in: Self.report).contains { $0.line == 99 })
    }

    @Test("the 10.x impacts taxonomy maps when legacy severity is absent")
    func impactsTaxonomy() {
        let report = """
        {
          "issues": [
            {
              "component": "p:A.swift",
              "line": 1,
              "message": "m1",
              "impacts": [ { "softwareQuality": "SECURITY", "severity": "HIGH" } ]
            },
            {
              "component": "p:A.swift",
              "line": 2,
              "message": "m2",
              "impacts": [ { "softwareQuality": "MAINTAINABILITY", "severity": "LOW" } ]
            },
            {
              "component": "p:A.swift",
              "line": 3,
              "message": "m3",
              "impacts": [ { "softwareQuality": "MAINTAINABILITY", "severity": "INFO" } ]
            }
          ]
        }
        """
        let severities = SonarReportParser.diagnostics(in: report).map(\.severity)
        #expect(severities == [.error, .warning, .note])
    }

    @Test("a merged top-level array of issues is accepted")
    func topLevelArray() {
        let report = """
        [ { "component": "p:A.swift", "line": 5, "severity": "MAJOR", "message": "m" } ]
        """
        let diagnostics = SonarReportParser.diagnostics(in: report)
        #expect(diagnostics.map(\.line) == [5])
    }

    @Test("garbage input yields no diagnostics instead of failing")
    func garbageInput() {
        #expect(SonarReportParser.diagnostics(in: "not json at all").isEmpty)
        #expect(SonarReportParser.diagnostics(in: "").isEmpty)
        #expect(SonarReportParser.diagnostics(in: "{\"unrelated\": true}").isEmpty)
    }

    @Test("duplicate issues collapse")
    func deduplicates() {
        let report = """
        {
          "issues": [
            { "component": "p:A.swift", "line": 1, "severity": "MAJOR", "message": "m" },
            { "component": "p:A.swift", "line": 1, "severity": "MAJOR", "message": "m" }
          ]
        }
        """
        #expect(SonarReportParser.diagnostics(in: report).count == 1)
    }

    @Test("chunked input parses identically", arguments: [1, 7, 4096])
    func chunkedEquivalence(chunkSize: Int) {
        let bytes = Array(Self.report.utf8)
        var parser = SonarReportParser()
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            parser.consume(bytes[index..<end])
            index = end
        }
        #expect(parser.finalize() == SonarReportParser.diagnostics(in: Self.report))
    }
}
