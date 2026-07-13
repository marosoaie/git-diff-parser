# git-diff-parser

Show only the build/lint diagnostics that a pull request actually touches.

Two subcommands, matching the two halves of the problem:

1. **`changes`** — parse a unified git diff and list every file + line number
   the PR **added or modified** (deleted lines are ignored: they can't carry
   warnings).
2. **`filter`** — parse a build/lint log, intersect it with those changed
   lines, and emit only the diagnostics that land on them — ready to post as
   PR annotations or comments.

Inputs are streamed, so kernel-sized diffs and gigabyte logs are fine — a
70 MB diff parses in ~0.2 s with flat memory (see
[implementation notes](INTERNALS.md)).

## Installation

Prebuilt arm64 binaries ship with each
[release](https://github.com/marosoaie/git-diff-parser/releases), with SHA-256
checksums attached. They are not yet notarized, so fetch them with `curl`/`gh
release download` (browser downloads get quarantined by Gatekeeper).

Or build from source (Swift 6.2+, macOS 14+):

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
`xcodebuild`, SwiftLint, and SwiftFormat all emit — everything else in the
log is ignored, so pipe the raw build output straight in:

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

This repository dogfoods exactly that recipe: every PR runs
[.github/workflows/pr.yml](.github/workflows/pr.yml), which executes the test
suite, runs SwiftLint, and filters both logs against the PR diff — new
warnings on changed lines annotate the PR and fail the job
(`--fail-on warning`).

**Danger / custom bot.** Use `--format json` and post each entry as an inline
comment via your API of choice; `file` is repo-relative and `line` is the
new-side line number, which is exactly what the GitHub review-comment API
(`side: RIGHT`) expects.

## Using the libraries

The package exports three library products, so other tooling — e.g. a
Danger-Swift plugin — can depend on exactly the layer it needs:

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

All model types are `Sendable` and the package builds with Swift 6.2 strict
concurrency.

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

## Matching semantics (the fine print)

- Log paths are usually absolute (`/Users/ci/checkout/Sources/App/Foo.swift`)
  while diff paths are repo-relative (`Sources/App/Foo.swift`). The matcher
  tries an exact match, then `--repo-root` stripping, then falls back to the
  longest suffix match aligned on `/` boundaries — so `FooBar.swift` never
  matches `Bar.swift`, and an ambiguous basename resolves to the most specific
  changed path.
- Only exact-duplicate log lines are deduplicated; two different messages on
  the same line are both kept.
- `remark:` (clang) is treated as `note`; clang's `fatal error:` is an
  `error`.

## Project documentation

- [INTERNALS.md](INTERNALS.md) — implementation details: streaming design,
  benchmarks, and how the parser is validated against real-world diffs.
- [AGENTS.md](AGENTS.md) — contribution conventions and coding style, written
  for humans and coding agents alike. Read it before contributing.
