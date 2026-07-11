import ArgumentParser
import Foundation
import GitDiffKit

/// Reads a file (or stdin, for "-") in fixed-size chunks so inputs never
/// have to fit in memory.
func forEachChunk(ofInput pathArgument: String, _ body: (Data) -> Void) throws {
    let chunkSize = 4 << 20
    let handle: FileHandle
    if pathArgument == "-" {
        handle = .standardInput
    } else {
        guard let opened = FileHandle(forReadingAtPath: pathArgument) else {
            throw ValidationError("Cannot read '\(pathArgument)'.")
        }
        handle = opened
    }
    defer {
        if pathArgument != "-" { try? handle.close() }
    }
    do {
        while true {
            // Without a pool per iteration, the autoreleased Data chunks
            // returned by FileHandle.read all stay alive until the process
            // exits, and "streaming" quietly degrades to whole-file memory.
            let reachedEnd = try autoreleasepool {
                guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else {
                    return true
                }
                body(data)
                return false
            }
            if reachedEnd { break }
        }
    } catch {
        throw ValidationError("Failed reading '\(pathArgument)': \(error.localizedDescription)")
    }
}

extension ChangedLines {
    /// Parses the diff at `pathArgument` ("-" for stdin) without loading it
    /// into memory at once.
    init(streamingFrom pathArgument: String) throws {
        var parser = DiffParser()
        try forEachChunk(ofInput: pathArgument) { parser.consume($0) }
        self = parser.finalize()
    }
}

enum JSON {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// Buffered stdout so per-line output stays fast for huge results.
struct BufferedStandardOutput {
    private var buffer = ""

    mutating func writeLine(_ line: String) {
        buffer += line
        buffer += "\n"
        if buffer.utf8.count >= 1 << 16 {
            flush()
        }
    }

    mutating func flush() {
        if !buffer.isEmpty {
            // print (not fputs) keeps the build clean under strict memory
            // safety; it writes through the same buffered C stdout.
            print(buffer, terminator: "")
            buffer = ""
        }
    }
}
