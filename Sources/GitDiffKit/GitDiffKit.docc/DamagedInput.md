# Handling Damaged Input

Diffs are untrusted input: GitDiffKit never traps on them, repairs what
it can, and tells you what it couldn't.

## Overview

A diff can be cut short by a timeout, mangled by a mail client, edited
by hand, or crafted to break whatever parses it. GitDiffKit treats every
diff as hostile:

- **It never traps.** No input makes the parser crash: arithmetic on
  the input's numbers is overflow-checked, and numbers too large to be
  real reject the line they're on.
- **It never throws.** Every input parses to a result; there is no
  error to handle.
- **It degrades locally.** The parser repairs what it can where it
  finds it, abandons a file it can't make sense of, and picks up again
  at the next file header, so the other files are read as usual.
- **It reports what it did** as ``DamageReport`` events, and never logs
  by itself.
- **Its memory is bounded.** No input can make the parser's own
  buffers grow without limit.

### Read damage reports

``DiffSummary`` and ``Diff`` keep every report, in input order, in
their `damage` arrays. This diff ends in the middle of a hunk that
declared four new lines:

```swift
let truncated = """
    diff --git a/notes.txt b/notes.txt
    --- a/notes.txt
    +++ b/notes.txt
    @@ -1,3 +1,4 @@
     first
    +second
    """
let summary = DiffSummary(diff: truncated)
summary.damage.forEach { report in
    print(report.severity, report.reason, "at line", report.lineNumber)
}
// info hunkCutShort at line 7
print(summary.files.map(\.addedLineCount))   // [1]
```

The file is still delivered, with the lines the hunk did have. A
report's ``DamageReport/lineNumber`` is the 1-based input line where
the damage was found (one past the last line for damage found at the
end of input), and ``DamageReport/file`` is the file's header as far as
it was read.

``ChangedLines`` and ``DiffParser`` don't keep reports. To see them
alongside changed lines, parse with a ``DiffSummary`` too, or write a
consumer whose ``DiffEventConsumer/damage(_:)`` keeps them (see
<doc:Streaming#Write-your-own-consumer>).

### Severity

A report's ``DamageReport/severity`` says how it affects the result:

- term ``DamageReport/Severity-swift.enum/info``: A local recovery. The
  parser repaired or skipped the damaged part — a header value, a hunk
  header, a line — and kept the rest of the file.
- term ``DamageReport/Severity-swift.enum/error``: The file was
  abandoned. It is missing from the results — no
  ``DiffEventConsumer/beginFile(_:rawHeader:)`` — and its lines are
  dropped until the next file starts.

Each ``DamageReport/Reason-swift.enum`` documents what was wrong and how
the parser recovered. Two reasons abandon a file:
``DamageReport/Reason-swift.enum/headerTooLarge``, for a header block
over the bounds below, and
``DamageReport/Reason-swift.enum/tooManyParents``, for a combined diff
of a merge with more than 64 parents. For a combined diff, an abandoned
file drops everything up to the next `diff ` line, since its hunks
can't be counted.

### Bounds

The parser's working memory has fixed bounds, whatever the input:

- **Lines.** A line is read up to ``ParsingOptions/maximumLineLength``
  bytes, 1 MiB by default and 64 MiB for the full model, and flagged
  ``LineInfo/isTruncated`` when it is longer, so a stream with no
  newlines can't grow the buffer that carries a line across chunks.
- **Header blocks.** A file's header block, which the parser holds until
  it is complete, is limited to 64 lines and 1 MiB.
- **Merges.** A combined diff can have at most 64 parents.
- **Numbers.** Hunk starts and counts above 2⁴⁸ reject the hunk header,
  and a similarity or dissimilarity over 100 percent is ignored, as
  `git apply` ignores it.

What the collectors keep grows as <doc:ChoosingACollector> describes.
One more thing grows with hostile input: the `damage` arrays, since a
diff of junk can earn one report per line. Cap or summarize them before
logging untrusted input.

### Reporting a vulnerability

If an input makes GitDiffKit trap, hang, or use memory beyond these
bounds, that is a security bug: please report it privately, as the
repository's
[security policy](https://github.com/marosoaie/git-diff-parser/blob/main/SECURITY.md)
describes.

## See Also

- ``DamageReport``
- ``DiffEventConsumer/damage(_:)``
- ``ParsingOptions``
