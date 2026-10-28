import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

/// Where each file of a large diff starts, for cutting windows of whole
/// files out of it.
///
/// The searches go through libc's `memchr` and `memcmp`, which run
/// optimized even in a debug build: a byte loop in Swift would take seconds
/// over the kernel diff's 74 MB, and corelibs Foundation's
/// `Data.range(of:in:)` minutes. Not `memmem`, which glibc before 2.39
/// (Ubuntu 22.04, RHEL 9), Windows and WASI don't declare.
struct DiffFileIndex {
    let data: Data
    /// Where each `diff ` line starts, then `data.count`.
    let fileStarts: [Int]
    /// Files with more than plain hunks: a creation, deletion, mode change,
    /// rename, copy, binary file, or `\ No newline at end of file`.
    let notableFiles: [Int]

    init(data: Data) {
        self.data = data
        let starts = (data.starts(with: Data("diff ".utf8)) ? [0] : [])
            + Self.offsets(of: "\ndiff ", in: data).map { $0 + 1 }
        fileStarts = starts + [data.count]
        let notableOffsets = Self.notableMarkers.flatMap { Self.offsets(of: $0, in: data) }
        notableFiles = Set(notableOffsets.compactMap { offset in
            Self.lastIndex(in: starts, atMost: offset)
        }).sorted()
    }

    var fileCount: Int { fileStarts.count - 1 }

    private static let notableMarkers = [
        "\nnew file mode ", "\ndeleted file mode ", "\nold mode ", "\nrename from ", "\ncopy from ",
        "\nBinary files ", "\nGIT binary patch", "\n\\ ",
    ]

    private static func offsets(of marker: String, in data: Data) -> [Int] {
        let pattern = Array(marker.utf8)
        return unsafe data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, let first = pattern.first else { return [] }
            let end = bytes.count - pattern.count
            return Array(sequence(state: 0) { start -> Int? in
                // A cursor: memchr finds each candidate's first byte, and a
                // candidate memcmp rejects resumes the scan right after it.
                var candidate = start
                while candidate <= end, let found = unsafe memchr(base + candidate, Int32(first), end + 1 - candidate) {
                    let offset = unsafe base.distance(to: UnsafeRawPointer(found))
                    if unsafe memcmp(found, pattern, pattern.count) == 0 {
                        start = offset + pattern.count
                        return data.startIndex + offset
                    }
                    candidate = offset + 1
                }
                return nil
            })
        }
    }

    /// Binary search: the last index of `sorted` whose element is at most
    /// `value`.
    private static func lastIndex(in sorted: [Int], atMost value: Int) -> Int? {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] <= value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    /// Two to `maximumFiles` consecutive files, at most `maximumBytes` in
    /// all unless the first alone is larger, starting at a notable file
    /// half the time. A start whose file is too large moves on to the next
    /// file that fits.
    func window(maximumFiles: Int, maximumBytes: Int, using generator: inout SplitMix64) -> DiffWindow {
        let drawn = generator.chance(1, in: 2) && !notableFiles.isEmpty
            ? generator.element(of: notableFiles)
            : generator.next(below: fileCount)
        let size = { (file: Int) in fileStarts[file + 1] - fileStarts[file] }
        let first = (drawn..<fileCount).first { size($0) <= maximumBytes }
            ?? (0..<fileCount).first { size($0) <= maximumBytes }
            ?? drawn
        let candidates = first..<min(fileCount, first + generator.next(in: 2...max(2, maximumFiles)))
        let fitting = candidates.filter { fileStarts[$0 + 1] - fileStarts[first] <= maximumBytes }
        let end = (fitting.last ?? first) + 1
        return DiffWindow(Array(data[fileStarts[first]..<fileStarts[end]]))
    }
}
