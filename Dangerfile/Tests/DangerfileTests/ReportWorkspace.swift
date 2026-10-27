import Foundation

/// A directory of its own, for a fixture context's workspace: the checkout
/// where the diagnostics rule reads the logs a test wrote.
struct ReportWorkspace {
    let path: String

    /// Writes each log, by its name, into a new directory.
    init(logs: [String: String]) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dangerfile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try logs.forEach { name, text in
            try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        path = url.path
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
