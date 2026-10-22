import Foundation

/// Runs fixture tooling (`git`, `xz`) found on `PATH`.
enum Subprocess {
    /// Returns the command's standard output, throwing if it exits nonzero.
    static func output(of arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        // An undrained stderr pipe can fill up and block the child.
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain before waiting, or a full pipe buffer deadlocks the child.
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError("""
                \(arguments.joined(separator: " ")) exited with \(process.terminationStatus); \
                is \(arguments[0]) installed and on PATH?
                """)
        }
        return output
    }
}
