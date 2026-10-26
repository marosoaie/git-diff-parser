# Contributing to git-diff-parser

Thanks for helping. This page is the short version for people;
[AGENTS.md](AGENTS.md) has the full conventions, written for people and
coding agents alike, and wins wherever the two differ.

## What belongs here

This repository is the GitDiffKit library: parsing unified diffs into
files, hunks, and lines. Tools built on it — build and lint log parsing,
pull request diagnostics, the `steward` CLI — live in
[swift-steward](https://github.com/marosoaie/swift-steward).

Two constraints shape every change:

- **No dependencies.** That's part of what the package offers; adding
  one needs the maintainer's agreement first.
- **No Foundation in `Sources/`**, so the library builds on every Apple
  platform and on Linux. The tests may use Foundation, guarding
  Darwin-only APIs with `#if canImport(Darwin)`.

For a bug, open an issue with the diff that shows it (or the smallest
part of it that does). For a security problem — an input that crashes
the parser, hangs it, or makes it use memory without bound — don't open
an issue: follow [SECURITY.md](SECURITY.md).

## Building and testing

You need Swift 6.2 or later: Xcode 26 or later on a Mac, or a Swift
toolchain on Linux (CI uses the `swift:6.2` Docker image).

```sh
swift build                                       # must finish with zero warnings
swift test                                        # the full suite
GIT_DIFF_PARSER_SKIP_NETWORK_TESTS=1 swift test   # without the downloaded fixtures
xcodebuild test -scheme git-diff-parser -destination platform=macOS
swiftlint lint --quiet                            # must print nothing
```

The real-world tests download large diffs (the Linux kernel's, about
70 MB) once and cache them in `~/Library/Caches/git-diff-parser-tests/`,
or `${XDG_CACHE_HOME:-~/.cache}/git-diff-parser-tests/` on Linux. They
also need `git` on your `PATH`, and `xz` on Linux. Tests must pass under
both `swift test` and `xcodebuild test`, which lay out build products
differently.

To build the documentation and check it for warnings, such as a broken
symbol link:

```sh
xcodebuild docbuild -scheme git-diff-parser -destination platform=macOS \
  -derivedDataPath .build/docs OTHER_DOCC_FLAGS=--warnings-as-errors
```

Every Swift sample in the README, the DocC articles, and the doc
comments is compiled and run by `DocumentationSampleTests`. When you
change a sample, change its copy there too; the suite fails when a
documented sample has no copy.

## Style

The full rules, with the reasons behind them, are in AGENTS.md. In
short:

- **Functional over imperative**: `map`, `filter`, `reduce`, and
  `forEach` over `for` and `while` loops. A loop that stays imperative,
  such as a measured hot path, says why in a comment.
- **Value types only**: structs and enums, no classes; behavior is
  injected as `@Sendable` closures, not inherited.
- **The Swift API Design Guidelines** for public API, and a doc comment
  on every public symbol that starts with a one-sentence summary.
  Elsewhere, comment only what the names don't say, and say why, not
  what.
- **Strict concurrency and memory safety** are on for every target, and
  a warning is a defect.
- **Never trap on untrusted input.** Overflow-check arithmetic on the
  input's numbers, never force-unwrap, and degrade locally: skip the
  damaged part, report it, keep parsing. The library doesn't throw on
  malformed input.
- **Streaming invariants.** Hot paths scan bytes; results must be
  identical for any chunking, down to 1-byte chunks; line sets are
  stored as merged ranges.
- **Multiline string literals** rather than `+`-joined ones.

## Tests

- Tests use swift-testing (`@Suite`, `@Test`), with sentence-style names
  such as "a diff truncated mid-hunk neither invents lines nor loses the
  next file".
- Keep test arguments short and build large inputs inside the test:
  swift-testing prints every argument, and a megabyte-long log line
  stalls GitHub's runners.
- Check results against an oracle where one exists, such as
  `git apply --numstat`, rather than against hand-computed numbers.
- Every bug fix comes with a regression test (see `MalformedInputTests`).
- Hostile input is tested by seeded mutations of the real diffs and a
  corpus (`MutationTests`): edits must never trap, must not change
  results across chunkings, and must leave the files they don't touch as
  they parse clean. A failure names its seed; rerun it with
  `GIT_DIFF_PARSER_MUTATION_SEEDS=<seed> swift test --filter MutationTests`,
  or a quoted range such as `'0..<100000'` for a longer run.
- Linux CI also fuzzes for a minute with libFuzzer, which Apple's
  toolchains don't ship; [Fuzz/FuzzTarget.swift](Fuzz/FuzzTarget.swift)
  says how to run it in the `swift:6.2` container.
- Changes that affect performance are benchmarked in release mode on
  the kernel diff before they merge; [INTERNALS.md](INTERNALS.md) has
  the numbers to stay within.

## Pull requests

- `main` takes changes only through pull requests, which the maintainer
  reviews and merges. CI runs the suite on macOS and Ubuntu, SwiftLint,
  a documentation build that fails on any warning, and the fuzzer.
- Write commit subjects in the imperative mood ("Parse rename headers"),
  with a body that explains why and what you checked.
- Say in the pull request which tests you ran.
- Never commit large binaries, and don't use Git LFS: SwiftPM clones
  this repository, and LFS breaks clones on machines without it. Large
  test fixtures are downloaded and cached at test time instead.
- The maintainer picks version numbers and tags releases.

By contributing, you agree that your contributions are licensed under
the [MIT License](LICENSE).
