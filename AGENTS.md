# git-diff-parser — contributor & agent guide

Conventions for working in this repository. Written for humans and coding
agents alike; nothing here is specific to any particular tool or model.

## What this is

A Swift library that parses unified git diffs into the files and lines they
touch. One product, `GitDiffKit`. Tooling built on top of it (build/lint
log parsing, PR diagnostics, the CLI) lives in
[swift-steward](https://github.com/marosoaie/swift-steward) — keep it out of
this repository.

The package takes **no dependencies**, and that is part of what it offers;
adding one needs the maintainer's explicit agreement. `ByteLineConsumer`
(chunk-to-line splitting) is internal.

## Commands

```sh
swift build                        # must complete with zero warnings
swift test                        # full suite (~10 s warm)
GIT_DIFF_PARSER_SKIP_NETWORK_TESTS=1 swift test   # offline subset
xcodebuild test -scheme git-diff-parser -destination platform=macOS
swift build -c release            # for benchmarks — never benchmark debug builds
swiftlint lint --quiet            # must print nothing
```

SwiftLint's configuration (`.swiftlint.yml`, with a `Tests/.swiftlint.yml`
override) encodes the mechanically checkable parts of the style below —
functional-preference rules are opted in, force unwraps are allowed in tests
only. Keep the whole tree violation-free; PR CI annotates violations. When a
rule fights a deliberate design decision, disable it in config or inline —
always with a comment saying why.

Real-world test fixtures resolve from
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
namespaces. Composition over inheritance: inject behavior as `@Sendable`
closures rather than subclassing.

**Swift API Design Guidelines** for all public API: argument labels that
read as prose (`contains(line:in:tolerance:)`), initializers for conversions
(`ChangedLines(diff:)`), `consume(...)`/`finalize()` for streaming builders.
Every public symbol carries a doc comment that starts with a one-sentence
summary; document behavioral quirks (normalization, performance caveats) at
the declaration. Public model types get explicit public memberwise
initializers. Encoded key names are wire contracts — decouple them from
Swift property names with `CodingKeys` instead of renaming properties.

**Strict concurrency and memory safety.** The package enables
`ExistentialAny`, `MemberImportVisibility`, `InferIsolatedConformances`,
`NonisolatedNonsendingByDefault`, and `strictMemorySafety()` on every
target. Keep the build warning-free — a warning is a defect. Mark value
types `Sendable`; a type that can't be (e.g. it stores a `Regex`) stays
deliberately non-Sendable rather than lying.

**Never trap on untrusted input.** Diffs are hostile input: overflow-check
arithmetic at parse boundaries (`multipliedReportingOverflow`), never
subscript a `split` result without `omittingEmptySubsequences: false`, order
comparisons so extreme values can't overflow, no force unwraps outside
tests. The library does not throw on malformed input — it degrades locally
(skips the damaged file, keeps parsing). Only the test support throws
(`FixtureError`, with a remediation hint).

**Streaming invariants.** Hot paths parse bytes (`ArraySlice<UInt8>`);
`String` and `Regex` are only reached after a cheap byte-level gate. Results
must be byte-for-byte identical for any input chunking (tested down to
1-byte chunks). Wrap `FileHandle.read` loops in `autoreleasepool` — without
it the autoreleased chunks accumulate and streaming silently degrades to
whole-file memory. Store line sets as merged ranges (`LineRangeSet`), never
per-line collections.

**Multiline string literals over `+`-concatenated literals** — for any
multi-part string (fixtures, messages), use `"""` with `\`
line-continuations and interpolation. Significant trailing whitespace inside
a literal is spelled `\u{20}` so editors and linters can't eat it.

**Comments only where names don't already say it.** Public symbols always
get the doc comment described above. Non-public methods, types, and
properties get one only when their names and parameter labels don't make
the behavior clear. Any comment is to the point and explains why, not
what — constraints, traps, and justifications (e.g. why a loop stays
imperative, why a pool per read iteration), never narration of the next
line.

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
  runners lay out build products and resource bundles differently.

## Git

- Commit subjects in imperative mood; bodies explain the why and any
  verification performed.
- `main` is PR-only; the maintainer reviews and merges.
- Never commit large binaries, and no Git LFS: SwiftPM consumers clone this
  repo, and LFS breaks checkouts on machines with missing or misconfigured
  `git-lfs`. Big test fixtures are downloaded and cached at test time
  instead.
- Releases are semver git tags — no binaries. The maintainer drives version
  numbers and tags releases; never tag unprompted. 0.x releases may break
  API; from 1.0 on, semver applies strictly.
