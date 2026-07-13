# git-diff-parser

Surfaces only the build/lint diagnostics that a pull request actually touches.

It does two things, matching the two halves of the problem:

1. **`changes`** — parse a unified git diff and list every file + line number
   the PR **added or modified** (deleted lines are ignored: they can't carry
   warnings).
2. **`filter`** — parse a build/lint log, intersect it with those changed
   lines, and emit only the diagnostics that land on them — ready to post as
   PR annotations or comments.

Requires Swift 6.2+ and macOS 14+. Built with strict concurrency and
[swift-argument-parser](https://github.com/apple/swift-argument-parser); no
other dependencies.

```sh
swift build -c release
# binary at .build/release/git-diff-parser
```

## `changes` — what lines does the PR touch?

```sh
git diff origin/main...HEAD | git-diff-parser changes -
git-diff-parser changes pr.diff --format text
```

Output (`json` default, or `text` as greppable `path:line` lines). Changed
lines are reported as closed ranges — contiguous runs stay compact no matter
how large the edit:

```json
[
  {
    "path": "Sources/App/Greeter.swift",
    "lineCount": 3,
    "ranges": [ { "start": 3, "end": 3 }, { "start": 5, "end": 6 } ]
  }
]
```

Line numbers are **new-side** (post-PR) numbers — the same ones your build log
and GitHub's PR view use. Modified lines count as added (git represents a
modification as remove + add). Deleted and binary files never appear; renames
appear under their new path, and only if they contain edits.

## `filter` — which diagnostics should the PR show?

```sh
git-diff-parser filter build.log --diff pr.diff --format github
```

The log is scanned for the de-facto standard clang format that `swiftc`,
`xcodebuild`, SwiftLint, and clang-tidy all emit — everything else in the log
is ignored, so pipe the raw build output straight in:

```
/path/to/File.swift:42:13: warning: variable 'x' was never used
```

| Option | Meaning |
|---|---|
| `--tool <tool>` | Log dialect: `generic` (default, any clang-style log), `xcodebuild`, `swiftlint`, or `swiftformat`. Tool-specific parsers also extract the violated rule — SwiftLint rule identifier, SwiftFormat rule name, clang warning flag — into the `rule` field (and the GitHub annotation title) |
| `--format json` | Structured output for your own PR-comment bot (default) |
| `--format github` | `::warning file=…,line=…::…` workflow commands — GitHub renders these as PR annotations automatically |
| `--format text` | clang-style lines, for humans |
| `--repo-root <path>` | Strip this prefix from absolute log paths. Usually unnecessary: unmatched absolute paths fall back to longest component-aligned suffix matching |
| `--tolerance <n>` | Also keep diagnostics within *n* lines of a change. `0` (default) is right for compiler warnings; `1`–`2` helps with lints that anchor on a declaration a line or two above the edit |
| `--fail-on <severity>` | Exit 1 if anything at/above `note`/`warning`/`error` matched — lets CI blocking be scoped to *new* problems only |

Duplicate diagnostics (same file/line/message, common in multi-target
`xcodebuild` runs) are collapsed. See `git-diff-parser help <subcommand>` for
the full reference.

## Getting the right diff

Use the **three-dot** diff against the merge base so you only see the PR's own
changes, not what happened on main since branching:

```sh
git fetch origin main
git diff origin/main...HEAD > pr.diff
```

On GitHub you can also download the PR's diff directly
(`https://github.com/OWNER/REPO/pull/N.diff`, or
`gh pr diff N > pr.diff`) — same format, parses identically.

## CI recipes

**GitHub Actions — zero-infrastructure annotations.** Emit workflow commands;
GitHub attaches them to the PR's changed lines in the Files tab:

```yaml
- run: git fetch origin ${{ github.base_ref }}
- run: |
    set -o pipefail
    xcodebuild build ... 2>&1 | tee build.log
- run: |
    git diff origin/${{ github.base_ref }}...HEAD \
      | .build/release/git-diff-parser filter build.log --diff - \
          --format github --fail-on error
```

**Danger / custom bot.** Use `--format json` and post each entry as an inline
comment via your API of choice; `file` is repo-relative and `line` is the
new-side line number, which is exactly what the GitHub review-comment API
(`side: RIGHT`) expects.

## Huge diffs: streaming by design

Both inputs are parsed as **byte streams**: the CLI reads 4 MiB chunks and
feeds them to incremental parsers, so neither the diff nor the log ever has
to fit in memory. Chunks may split lines — or multi-byte UTF-8 characters —
anywhere; results are byte-for-byte identical for any chunking (tested down
to 1-byte chunks). Changed lines are stored as merged ranges
(`LineRangeSet`), so memory scales with the number of *edits*, not lines: a
full-file rewrite is one range.

Measured on real-world input (Apple Silicon, release build) — the Linux
kernel v6.6 → v6.7 release diff, one of the largest diffs in open source,
plus a 6× concatenation of it:

| Input | Size | Time | Peak RSS |
|---|---|---|---|
| `changes`, kernel 6.6→6.7 diff (12,057 files, 906k added lines) | 70 MB | 0.2 s | 67 MB |
| `changes`, 6× concatenated kernel diff | 422 MB | 0.7 s | 67 MB |
| same, piped through stdin | 422 MB | 0.7 s | 67 MB |
| `filter`, 1.9M-line build log against the kernel diff | 94 MB + 70 MB | 2.4 s | 24 MB |

Peak memory is flat from 70 MB to 422 MB of input — the residual is the
result itself (12k paths, ~250k ranges), not the diff.

## Testing against real-world diffs

`swift test` runs two kinds of suites:

- **Unit and fixture tests** — parser edge cases (renames, quoted paths,
  CRLF, chunk boundaries, diff-syntax-lookalike content) plus a committed
  real PR diff (swiftlang/swift #70000) with independently verified
  expectations.
- **Real-world large-diff tests** — parse the Linux kernel v6.6→v6.7 release
  patch (~70 MB), GitHub's redis 7.0→7.2 compare diff (renames), and
  swift-argument-parser's 1.0→1.5 compare diff, then cross-check every
  per-file changed-line count against git's own patch parser
  (`git apply --numstat`). The kernel and redis diffs are committed as
  xz-compressed **Git LFS** fixtures; the swift-argument-parser diff is always
  downloaded, so the network path stays exercised. Downloads are cached in
  `~/Library/Caches/git-diff-parser-tests/`, and a clone without `git lfs`
  falls back to downloading automatically.

Set `GIT_DIFF_PARSER_SKIP_NETWORK_TESTS=1` to skip the real-world suite (e.g.
in offline environments).

## Library use

The package exports three library products, so other internal tooling — e.g.
a Danger-Swift plugin — can depend on exactly the layer it needs:

| Product | What it does |
|---|---|
| `GitDiffKit` | Unified git diffs → changed files and line ranges (`DiffParser`, `ChangedLines`) |
| `BuildLogKit` | Build/lint logs → diagnostics. `ClangStyleLogParser` handles any clang-style log; `XcodeLogParser`, `SwiftLintLogParser`, and `SwiftFormatLogParser` additionally extract the violated rule. All conform to `LogParsing` |
| `DiffDiagnostics` | The join: `DiagnosticMatcher` filters diagnostics to the lines a diff touches (depends on both of the above) |

```swift
// Package.swift
.package(url: "https://github.com/marosoaie/git-diff-parser.git", branch: "main"),
// target dependencies (pick what you need):
.product(name: "GitDiffKit", package: "git-diff-parser"),
.product(name: "BuildLogKit", package: "git-diff-parser"),
.product(name: "DiffDiagnostics", package: "git-diff-parser"),
```

All model types are `Sendable`; the package builds with Swift 6.2 strict
concurrency plus the upcoming-feature flags (`ExistentialAny`,
`MemberImportVisibility`, `InferIsolatedConformances`,
`NonisolatedNonsendingByDefault`, strict memory safety).

```swift
import BuildLogKit
import DiffDiagnostics
import GitDiffKit

// Whole-string convenience — or stream chunks into a DiffParser for
// inputs that shouldn't be held in memory:
var parser = DiffParser()
while let chunk = nextChunk() { parser.consume(chunk) }   // Data, [UInt8], or String
let changes = parser.finalize()                           // == ChangedLines(diff: wholeText)

changes.contains(line: 42, in: "Sources/App/Foo.swift")   // binary search
let kept = DiagnosticMatcher.match(
    SwiftLintLogParser.diagnostics(in: lintLog),          // rule-aware
    against: changes
)
```

## Conventions

Coding style and project conventions — functional style over loops, value
types only, strict concurrency, never trapping on untrusted input, oracle-
based testing — live in [AGENTS.md](AGENTS.md), written to be readable by
both humans and coding agents (any tool, any model). Read it before
contributing.

## Matching semantics (the fine print)

- Log paths are usually absolute (`/Users/ci/checkout/Sources/App/Foo.swift`)
  while diff paths are repo-relative (`Sources/App/Foo.swift`). The matcher
  tries an exact match, then `--repo-root` stripping, then falls back to the
  longest suffix match aligned on `/` boundaries — so `FooBar.swift` never
  matches `Bar.swift`, and an ambiguous basename resolves to the most specific
  changed path.
- Only exact-duplicate log lines are deduplicated; two different messages on
  the same line are both kept.
- `remark:` (clang) is treated as `note`.
