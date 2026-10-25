@testable import GitDiffKit

/// Renders scanned files the way `git apply` prints them, so the parser's
/// headers compare byte-for-byte against git's own reading of a diff.
extension GitApply {
    /// What `git apply --summary` prints, mirroring apply.c's
    /// `summary_patch_list`.
    static func summary(of files: [FileTally.File]) -> [UInt8] {
        files.flatMap { summaryLines(of: $0.header) }
    }

    /// What `git apply --numstat -z` prints, mirroring apply.c's
    /// `numstat_patch_list`.
    static func numstat(of files: [FileTally.File]) -> [NumstatEntry] {
        files.map { file in
            NumstatEntry(
                added: file.header.isBinary ? nil : file.addedLines,
                deleted: file.header.isBinary ? nil : file.deletedLines,
                path: (file.header.newPath ?? file.header.oldPath)?.bytes ?? []
            )
        }
    }

    private static func summaryLines(of header: FileHeader) -> [UInt8] {
        let oldPath = header.oldPath?.bytes ?? []
        let newPath = header.newPath?.bytes ?? []
        // git keeps one score per patch, from whichever index line it read.
        let score = header.dissimilarity ?? 0
        switch header.change {
        case .added:
            return fileModeName("create", mode: header.newMode, path: newPath)
        case .deleted:
            return fileModeName("delete", mode: header.oldMode, path: oldPath)
        case .renamed(let similarity):
            return renameCopy("rename", oldPath, newPath, score: similarity ?? score)
                + modeChange(header, path: nil)
        case .copied(let similarity):
            return renameCopy("copy", oldPath, newPath, score: similarity ?? score)
                + modeChange(header, path: nil)
        case .modified where score != 0:
            return text(" rewrite ") + newPath + text(" (\(score)%)\n") + modeChange(header, path: nil)
        case .modified:
            return modeChange(header, path: newPath)
        }
    }

    private static func fileModeName(_ verb: String, mode: FileMode?, path: [UInt8]) -> [UInt8] {
        guard let mode else { return text(" \(verb) ") + path + text("\n") }
        return text(" \(verb) mode \(octal(mode)) ") + path + text("\n")
    }

    private static func modeChange(_ header: FileHeader, path: [UInt8]?) -> [UInt8] {
        guard let old = header.oldMode, let new = header.newMode, canonical(old) != canonical(new) else { return [] }
        let change = text(" mode change \(octal(old)) => \(octal(new))")
        return change + (path.map { text(" ") + $0 } ?? []) + text("\n")
    }

    /// `rename a/{b => c} (N%)`: leading directories both paths share are
    /// written once, compared a whole component at a time.
    private static func renameCopy(_ verb: String, _ old: [UInt8], _ new: [UInt8], score: Int) -> [UInt8] {
        let slash = UInt8(ascii: "/")
        let oldDirectories = old.split(separator: slash, omittingEmptySubsequences: false).dropLast()
        let newDirectories = new.split(separator: slash, omittingEmptySubsequences: false).dropLast()
        let shared = zip(oldDirectories, newDirectories).prefix { $0 == $1 }.count
        let prefixLength = oldDirectories.prefix(shared).reduce(0) { $0 + $1.count + 1 }
        let names = shared == 0
            ? old + text(" => ") + new
            : old.prefix(prefixLength) + text("{") + old.dropFirst(prefixLength) + text(" => ")
                + new.dropFirst(prefixLength) + text("}")
        return text(" \(verb) ") + names + text(" (\(score)%)\n")
    }

    /// apply.c's `canon_mode`, which git applies to every mode it parses:
    /// permission bits reduced to 644 or 755, and any type that isn't a
    /// regular file, link, or directory taken as a gitlink.
    private static func canonical(_ mode: FileMode) -> UInt32 {
        switch mode.rawValue & 0o170000 {
        case 0o100000: mode.rawValue & 0o100 == 0 ? 0o100644 : 0o100755
        case 0o120000: 0o120000
        case 0o040000: 0o040000
        default: 0o160000
        }
    }

    private static func octal(_ mode: FileMode) -> String {
        let digits = String(canonical(mode), radix: 8)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    private static func text(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }
}
