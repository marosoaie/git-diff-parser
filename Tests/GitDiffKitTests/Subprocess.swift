import Foundation

/// Runs fixture tooling (`git`, `xz`) found on `PATH`.
enum Subprocess {
    /// Returns the command's standard output, throwing with its standard
    /// error if it exits nonzero.
    ///
    /// Runs in `directory` when given, with `environment` added to the
    /// test process's own, reading standard input from `input` when given.
    static func output(
        of arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        input: URL? = nil
    ) throws -> Data {
        #if canImport(Darwin)
        // Swift concurrency's threads drain no autorelease pool between
        // calls: without one per call, the oracle sweep's parallel cases
        // lost a few of their 17,000 git runs to EBADF, every time.
        try autoreleasepool { try run(arguments, in: directory, environment: environment, input: input) }
        #else
        try run(arguments, in: directory, environment: environment, input: input)
        #endif
    }

    private static func run(
        _ arguments: [String], in directory: URL?, environment: [String: String], input: URL?
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let stdin = try input.map(FileHandle.init(forReadingFrom:))
        defer { try? stdin?.close() }
        if let stdin {
            process.standardInput = stdin
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        // A file rather than a pipe: an undrained stderr pipe can fill up and
        // block the child while we are draining stdout.
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-parser-tests-\(UUID().uuidString).stderr")
        guard FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw FixtureError("could not create \(stderrURL.path) to capture stderr")
        }
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }
        process.standardError = stderr

        try process.run()
        // Drain before waiting, or a full pipe buffer deadlocks the child.
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw FixtureError("""
                \(arguments.joined(separator: " ")) exited with \(process.terminationStatus) \
                (is \(arguments[0]) installed and on PATH?): \(message.prefix(1000))
                """)
        }
        return output
    }
}
