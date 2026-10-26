// A libFuzzer target, Linux only: Apple's toolchains don't ship libFuzzer,
// and SwiftPM can't link a libFuzzer executable, so the library is built
// instrumented and this file linked with swiftc (on macOS, in the
// `swift:6.2` container):
//
//     swift build -c release --target GitDiffKit --scratch-path .build/fuzz \
//         -Xswiftc -sanitize=fuzzer,address
//     swiftc -O -sanitize=fuzzer,address -parse-as-library -strict-memory-safety \
//         -I .build/fuzz/release/Modules Fuzz/FuzzTarget.swift \
//         .build/fuzz/release/GitDiffKit.build/*.o -o .build/fuzz/GitDiffKitFuzz
//     mkdir -p .build/fuzz/corpus
//     .build/fuzz/GitDiffKitFuzz -max_total_time=60 .build/fuzz/corpus Fuzz/Corpus
//
// libFuzzer adds what it finds to the first folder, so Fuzz/Corpus, the
// committed seeds, stays as it is.

import GitDiffKit

/// libFuzzer's entry point: parses the input with every collector, whole
/// and in chunks whose size the input's first byte picks, and traps if
/// chunking changes a result. A trap of the parser's own is a finding too.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let bytes = unsafe [UInt8](UnsafeRawBufferPointer(start: start, count: count))
    FuzzTarget.check(bytes)
    return 0
}

/// What one fuzz input must satisfy.
enum FuzzTarget {
    static func check(_ bytes: [UInt8]) {
        let chunkSize = 1 + Int(bytes.first ?? 0) % 64
        precondition(changedLines(of: bytes) == changedLines(of: bytes, chunkSize: chunkSize))
        precondition(summary(of: bytes) == summary(of: bytes, chunkSize: chunkSize))
        precondition(model(of: bytes) == model(of: bytes, chunkSize: chunkSize))
    }

    private static func changedLines(of bytes: [UInt8], chunkSize: Int = .max) -> ChangedLines {
        var parser = DiffEventParser(consumer: ChangedLines.Collector())
        chunks(of: bytes, size: chunkSize).forEach { parser.consume($0) }
        return parser.finalize().changedLines
    }

    private static func summary(of bytes: [UInt8], chunkSize: Int = .max) -> DiffSummary {
        var parser = DiffEventParser(consumer: DiffSummary.Collector())
        chunks(of: bytes, size: chunkSize).forEach { parser.consume($0) }
        return parser.finalize().summary
    }

    private static func model(of bytes: [UInt8], chunkSize: Int = .max) -> Diff {
        var parser = DiffEventParser<Diff.Collector>()
        chunks(of: bytes, size: chunkSize).forEach { parser.consume($0) }
        return parser.finalize().diff
    }

    private static func chunks(of bytes: [UInt8], size: Int) -> [ArraySlice<UInt8>] {
        stride(from: 0, to: bytes.count, by: size).map { bytes[$0..<min(bytes.count, $0 &+ size)] }
    }
}
