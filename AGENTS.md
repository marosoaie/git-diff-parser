# git-diff-parser — contributor & agent guide

Conventions for working in this repository. Written for humans and coding
agents alike; nothing here is specific to any particular tool or model.

## What this is

A Swift package that surfaces build/lint diagnostics only on lines a pull
request touches. Four products, strict dependency direction:

| Product | Depends on | Purpose |
|---|---|---|
| `GitDiffKit` | – | Unified git diffs → changed files + line ranges |
| `BuildLogKit` | – | Build/lint logs → `[Diagnostic]` (xcodebuild, SwiftLint, SwiftFormat parsers) |
| `DiffDiagnostics` | both above | The join: which diagnostics land on changed lines |
| `git-diff-parser` (CLI) | all three | `changes` and `filter` subcommands |

`GitDiffKit` and `BuildLogKit` must never import each other; only
`DiffDiagnostics` couples them. `StreamParsing` is an internal target
(chunk-to-line splitting, shared via the `package` access level) — never
expose it as a product. Libraries take no third-party dependencies;
swift-argument-parser is allowed in the CLI target only.

## Commands

```sh
swift build                        # must complete with zero warnings
swift test                        # full suite (~20 s warm)
GIT_DIFF_PARSER_SKIP_NETWORK_TESTS=1 swift test   # offline subset
xcodebuild test -scheme git-diff-parser-Package -destination platform=macOS
swift build -c release            # for benchmarks — never benchmark debug builds
swiftlint lint --quiet            # must print nothing
```

SwiftLint's configuration (`.swiftlint.yml`, with a `Tests/.swiftlint.yml`
override) encodes the mechanically checkable parts of the style below —
functional-preference rules are opted in, force unwraps are allowed in tests
only. Keep the whole tree violation-free; PR CI additionally annotates and
fails on violations on PR-touched lines. When a rule fights a deliberate
design decision, disable it in config or inline — always with a comment
saying why.

Real-world test fixtures resolve from Git LFS files, then
`~/Library/Caches/git-diff-parser-tests/`, then the network.

## Coding style

**Functional over imperative.** Prefer `map` / `filter` / `compactMap` /
`reduce` / `flatMap` / `contains(where:)` / `forEach` over `for` and `while`
loops wherever practical. An imperative loop is the exception and needs to
earn its place: a measured hot path (byte-level scanning, binary search), a
stateful cursor that combinators would obscure, or a mid-scan feedback
condition that isn't a clean fold. When you keep one, say why in a comment.
When output size is unbounded, stream through `forEach` or `.lazy` rather
than materializing intermediate arrays.

**Value types only.** Structs and enums; no classes. Caseless enums as
namespaces. Composition over inheritance: tool-specific behavior is injected
as `@Sendable` closures (see `ClangStyleLogParser`'s `refine` hook), not
subclassed.

**Swift API Design Guidelines** for all public API: argument labels that
read as prose (`contains(line:in:tolerance:)`), initializers for conversions
(`ChangedLines(diff:)`), `consume(...)`/`finalize()` for streaming builders.
Every public symbol carries a doc comment that starts with a one-sentence
summary; document behavioral quirks (normalization, performance caveats) at
the declaration. Public model types get explicit public memberwise
initializers. JSON key names are wire contracts — decouple them from Swift
property names with `CodingKeys` instead of renaming properties.

**Strict concurrency and memory safety.** The package enables
`ExistentialAny`, `MemberImportVisibility`, `InferIsolatedConformances`,
`NonisolatedNonsendingByDefault`, and `strictMemorySafety()` on every
target. Keep the build warning-free — a warning is a defect. Mark value
types `Sendable`; a type that can't be (e.g. it stores a `Regex`) stays
deliberately non-Sendable rather than lying.

**Never trap on untrusted input.** Diffs and logs are hostile input:
overflow-check arithmetic at parse boundaries
(`multipliedReportingOverflow`), never subscript a `split` result without
`omittingEmptySubsequences: false`, order comparisons so extreme values
can't overflow, no force unwraps outside tests. Libraries do not throw on
malformed input — they degrade locally (skip the damaged file, keep
parsing). Only the CLI throws (`ValidationError`, `ExitCode`) and only the
test support throws `FixtureError` (with a remediation hint).

**Streaming invariants.** Hot paths parse bytes (`ArraySlice<UInt8>`);
`String` and `Regex` are only reached after a cheap byte-level gate. Results
must be byte-for-byte identical for any input chunking (tested down to
1-byte chunks). Wrap `FileHandle.read` loops in `autoreleasepool` — without
it the autoreleased chunks accumulate and streaming silently degrades to
whole-file memory. Store line sets as merged ranges (`LineRangeSet`), never
per-line collections.

**Multiline string literals over `+`-concatenated literals** — for any
multi-part string (fixtures, messages, help text), use `"""` with `\`
line-continuations and interpolation. Significant trailing whitespace inside
a literal is spelled `\u{20}` so editors and linters can't eat it.

**Comments explain why, not what** — constraints, traps, and justifications
(e.g. why a loop stays imperative, why a pool per read iteration), never
narration of the next line. Keep them few and short.

## Testing

- swift-testing (`@Suite`/`@Test`) with sentence-style names
  ("a diff truncated mid-hunk neither invents lines nor loses the next
  file"); parameterized tests via `arguments:`; traits for `.serialized`,
  `.timeLimit`, `.enabled(if:)`.
- Validate against **oracles**, not hand-computed expectations, where one
  exists: per-file changed-line counts are cross-checked against
  `git apply --numstat` on real diffs (Linux kernel, redis,
  swift-argument-parser).
- Every bug fix lands with a regression test (see `MalformedInputTests`).
- Performance-relevant changes are benchmarked on the kernel-diff fixtures
  in release mode before merging; parsing throughput (~0.2 s / 70 MB) and
  flat peak memory are the budget.
- Tests must pass under both `swift test` and Xcode/`xcodebuild test` — the
  runners lay out build products differently (see `CommandLineTool.url`).

## Git

- Commit subjects in imperative mood; bodies explain the why and any
  verification performed.
- Large binary fixtures go through Git LFS (`*.xz` is tracked); anything
  over ~1 MB that isn't LFS needs a good reason.
- Releases: bump `CommandConfiguration.version` via PR, then run the
  "Release" workflow (Actions tab) with the matching semver number and
  branch. It tests, packages the arm64 binary, tags `vX.Y.Z`, and publishes
  a GitHub release with generated notes.
