import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where each file of a large diff starts, for cutting windows of whole
/// files out of it.
///
/// The searches go through libc's `memmem`, which runs optimized even in a
/// debug build: a byte loop in Swift would take seconds over the kernel
/// diff's 74 MB, and corelibs Foundation's `Data.range(of:in:)` minutes.
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
            guard let base = bytes.baseAddress else { return [] }
            let count = bytes.count
            return Array(sequence(state: 0) { start -> Int? in
                guard start < count, let found = unsafe memmem(base + start, count - start, pattern, pattern.count)
                else { return nil }
                let offset = unsafe base.distance(to: UnsafeRawPointer(found))
                start = offset + pattern.count
                return data.startIndex + offset
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
