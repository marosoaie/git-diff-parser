# Security policy

GitDiffKit parses diffs, and diffs are untrusted input: a pull request's
diff is written by whoever opened it, and a diff fetched from anywhere
can be truncated, corrupted, or crafted to break the program reading
it. The library is built so that no input can crash it, hang it, or
make it use memory without bound.

## What the library guarantees

- **It never traps.** No input makes the parser crash. Arithmetic on
  the input's numbers is overflow-checked, numbers too large to be real
  (hunk starts and counts above 2⁴⁸, modes over 32 bits) are rejected
  rather than wrapped, and the library has no force unwraps (SwiftLint
  enforces it) and no `unsafe` code.
- **It never throws.** Every input parses to a result.
- **It degrades locally.** The parser repairs damage where it finds it,
  such as a hunk cut short, a line without a marker, or a header value
  that doesn't parse, or it abandons the damaged file. Either way it
  picks up again at the next file header, so the damage stays inside
  the file it is in.
- **It reports damage instead of hiding it.** Each repair or abandoned
  file is a `DamageReport` event with its reason, the input line, the
  file, and a severity: `info` for a local recovery, `error` for an
  abandoned file. The library never logs; callers decide what to show.
- **Its working memory is bounded.** Whatever the input, the parser's
  own buffers stay within fixed limits:
  - the **line cap**: a line is read up to
    `ParsingOptions.maximumLineLength` bytes, 1 MiB by default and
    64 MiB for the full model, and flagged `isTruncated` when it is
    longer, so input without newlines can't grow the buffer that
    carries a line across chunks;
  - a file's **header block**: at most 64 lines and 1 MiB, or the file
    is abandoned;
  - a merge's **combined diff**: at most 64 parents, or the file is
    abandoned.
- **Results don't depend on chunking.** The same input gives the same
  result however it is split into chunks, down to one byte at a time.

What the collectors keep grows with the input, as documented: the
changed-line ranges with the number of edits, the summary with the
number of files, and the full model with the diff's content (about 2.5×
its size). On hostile input, the `damage` arrays of `DiffSummary` and
`Diff` can hold a report for every line. If you parse untrusted diffs
into the full model, bound the input's size first.

The [Handling Damaged Input](Sources/GitDiffKit/GitDiffKit.docc/DamagedInput.md)
article shows how to read the reports.

## How it is tested

- Every hostile-input fix comes with a regression test, collected in
  `MalformedInputTests`.
- The parser's results are cross-checked against git's own patch parser
  (`git apply --numstat` and `--summary`) on the Linux kernel, redis,
  and swift-argument-parser diffs, and on a test repository built with
  `git fast-import` to hold every kind of change and every kind of path.
- Streaming tests feed inputs at chunk sizes down to one byte.
- The package builds with Swift's strict memory safety checking
  (`strictMemorySafety()`), and CI treats every warning as an error.

## What counts as a vulnerability

Please report privately any input that makes GitDiffKit:

- crash, trap, or read or write memory out of bounds;
- take time out of proportion to the input's size, or hang;
- use memory beyond the bounds above;
- change the result for a file the damage isn't in.

A diff that GitDiffKit reads differently from git, without any of the
effects above, is an ordinary bug: please open an issue.

## Reporting a vulnerability

Report it through GitHub's private vulnerability reporting: on the
repository's **Security** tab, choose **Report a vulnerability**. The
report stays private between you and the maintainer until a fix is
published. Include the input that triggers the problem, or a way to
generate it, and the GitDiffKit version or commit.

If the button isn't there, open an issue that asks for a private way to
send a report, without the details.

## Supported versions

GitDiffKit is pre-1.0. Fixes land on `main` and ship in the next
release; earlier releases don't get backported fixes.
