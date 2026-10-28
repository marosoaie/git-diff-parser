# Validation record

What was run to check GitDiffKit against git and GitHub on diffs beyond
the committed fixtures, and on platforms beyond the two CI tested, as of
2026-10-28 (plan step 5.0, Track A). Each section says how to rerun it.
The fixture suites `swift test` always runs are described in
[INTERNALS.md](../INTERNALS.md#validation-against-real-world-diffs).

## At a glance

| Check | Scale | Result |
|---|---|---|
| [Every commit of 9 clones](#every-commit-of-local-clones) against `git show --numstat` | 137,159 commits | All match, after two differences of git's own reading |
| [Real pull requests](#real-pull-requests-against-github) against GitHub's per-file counts | 106 pull requests, 23 repositories | All match |
| [Git settings](#git-settings-that-change-the-diff) that change the diff's text | 6 settings | 5 match; a coloured diff reads as no files, as now documented ([A1](#a1-coloured-diffs)) |
| [Platforms in CI](#platforms-in-ci), every pull request | 6 jobs: macOS, 4 more Apple platforms, Linux on x86_64 and arm64, Ubuntu 22.04, Swift 6.4.1 | All pass |
| [Platforms tried once](#platforms-tried-once) | 5 | Tests pass on 2; the library builds on all 5 |

## Environment

Local runs: macOS 26.6.2 on an Apple M4 (10 cores), Xcode 27.1
(Swift 6.4), git 2.54.0 (Apple Git-157). CI runs name their own versions
below.

## Every commit of local clones

`OracleSweepTests`, off unless `GIT_DIFF_PARSER_SWEEP_CLONES` lists clones
(separated by colons). For every commit reachable from each clone's
`HEAD` it compares the summary of `git show`'s output with
`git show --numstat`, file by file, merges against their first parent and
with copy detection on (`--diff-merges=first-parent --find-copies`). It
also requires that neither the summary nor the full model reports damage
and that the full model renders `git show`'s output back byte for byte.
Git's configuration is shut out (`GIT_CONFIG_GLOBAL=/dev/null`,
`GIT_CONFIG_NOSYSTEM=1`). Each clone's commits are split across one test
case per core.

The clones were picked for what the committed fixtures lack, and the
sweep counts what it saw, so the table says what each one exercised:

| Repository | Branch and head swept | Commits | Dates | Most of what it adds |
|---|---|---|---|---|
| [git/git](https://github.com/git/git) | `master` 37b3475fb530 | 82,605 | 2005-04 to 2026-10 | 4,653 renames, 288 copies, 599 symlinks, 328 mode changes; a 17.7 MB commit |
| [obsproject/obs-studio](https://github.com/obsproject/obs-studio) | `master` 2735cc48ce60 | 15,816 | 2013-09 to 2026-10 | 480 submodule changes, 746 binary files |
| [vitejs/vite](https://github.com/vitejs/vite) | `main` cce559ab158c | 9,846 | 2020-04 to 2026-10 | A monorepo's lockfile and renames (1,480); 21 quoted paths |
| [ReactiveCocoa/ReactiveCocoa](https://github.com/ReactiveCocoa/ReactiveCocoa) | `master` f2d9bd56ae9f | 8,662 | 2012-03 to 2024-05 | 777 submodule changes, 3,312 renames, Xcode projects |
| [lodash/lodash](https://github.com/lodash/lodash) | `main` 2b5e6f7399a7 | 7,710 | 2009-10 to 2026-09 | Generated builds (to 2.4 MB a commit), 26,746 CRLF lines, 133 mode changes |
| [CyC2018/CS-Notes](https://github.com/CyC2018/CS-Notes) | `master` b07e0972aff9 | 4,274 | 2018-02 to 2026-10 | 19,396 quoted (non-ASCII) paths, 24,606 binary files, 472,227 CRLF and 27,892 non-UTF-8 lines |
| [sharkdp/bat](https://github.com/sharkdp/bat) | `master` a9aa73d21545 | 4,062 | 2018-04 to 2026-10 | 522 submodule changes, and the sweep's only 2 paths that aren't UTF-8 |
| [axios/axios](https://github.com/axios/axios) | `v1.x` 8f4ed5691168 | 2,257 | 2014-08 to 2026-10 | Lockfiles and built bundles (to 2.7 MB a commit) |
| [JamesNK/Newtonsoft.Json](https://github.com/JamesNK/Newtonsoft.Json) | `master` 52fa3aef1f2c | 1,927 | 2007-09 to 2026-09 | 361,137 CRLF lines, 336 binary files |
| **All nine** | | **137,159** | | 542,468 files: 16,607 renames, 2,831 copies, 26,815 binary files, 1,858 submodule changes, 640 symlinks, 510 mode changes, 19,450 quoted paths; 866,607 CRLF lines, 28,581 lines that aren't UTF-8, 23,225 without a final newline |

Every commit was walked; none needed the
`GIT_DIFF_PARSER_SWEEP_MAX_COMMITS` cap. The Linux kernel was left out,
as its release diff is already a fixture.

The last run, of the code as of this record, took 17 minutes (1,019 s)
on the machine above, ten cases per clone: every one of the 137,159
commits matched git, file by file, with no damage, and rendered back
byte for byte.

Two differences are git's, not the text's, and the test makes them
comparable rather than counting them as mismatches;
`git apply --numstat`, which reads only the text as GitDiffKit does,
agrees with GitDiffKit on both:

- **A type change** (a file replaced by a symlink, say) is two patches
  in the diff, a deletion and a creation of the same path, but one line
  in `git show --numstat`. The test folds the two into one. Seen in
  git.git (the `RelNotes` symlink, 2efbb7f5218d and three more) and vite
  (a0c950e30945).
- **A content-free binary file**, a pure rename, copy or mode change of
  one, has no content in the diff, so the text can't say it is binary;
  `git show` reads the blob and prints `-`, and the test counts git's
  `-` as zero there. Seen in lodash (53326bef33f9, bda869ea54d5) and a
  100% copy in ReactiveCocoa.

To rerun it on the same commits, clone each repository bare, pin its
branch to the head swept, and list the clones:

```sh
C=~/Library/Caches/git-diff-parser-sweep
git clone --bare --single-branch https://github.com/git/git.git "$C/git.git"
git -C "$C/git.git" update-ref refs/heads/master 37b3475fb530c14109211faca33716a173db61ed
# …and the same for each row of the table…
GIT_DIFF_PARSER_SWEEP_CLONES="$C/git.git:$C/vite.git" swift test --filter OracleSweepTests
```

The nine clones take 807 MB. A run prints one line per case with what
its commits held; failures name the commits, the first five in detail.

## Real pull requests against GitHub

`GitHubPullRequestTests`, off unless `GIT_DIFF_PARSER_GITHUB_ORACLE` is
set. For each listed pull request it compares GitHub's file list
(`GET /repos/{owner}/{repo}/pulls/{number}/files`, additions and
deletions per path) with the summary of the diff GitHub serves for it
(`GET /repos/{owner}/{repo}/pulls/{number}` with
`Accept: application/vnd.github.diff`), and requires no damage and a
byte-for-byte round trip of the full model. Both responses are cached
under the fixture cache in `github-pull-requests/`, as a merged pull
request's diff doesn't change; cases run one at a time, as GitHub asks of
API clients.

```sh
GITHUB_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p') \
  GIT_DIFF_PARSER_GITHUB_ORACLE=1 swift test --filter GitHubPullRequestTests
```

The token only lifts GitHub's rate limit of 60 requests an hour; a run
from the cache needs neither it nor the network.

The 106 pull requests, listed in
[GitHubPullRequests.swift](../Tests/GitDiffKitTests/GitHubPullRequests.swift):

- seven merged in September 2026 from each of swiftlang/swift,
  apple/swift-nio, microsoft/vscode, vercel/next.js, rust-lang/rust,
  python/cpython, nodejs/node, dotnet/runtime, microsoft/PowerToys,
  Homebrew/homebrew-core, flutter/flutter and kubernetes/kubernetes;
- the largest found that GitHub still serves: up to 265 files
  (rust-lang/rust#164928), and up to 254,275 lines in 14.6 MB
  (microsoft/TypeScript#64620);
- thirteen found by searching for what those lack, and confirmed in
  their diffs: binary files, mode changes, submodules and symlinks.

All 106 match: 2,253 files, 106 binary files, 250 mode changes,
51 renames, 6 symlinks, 4 submodules, 281,761 CRLF lines, 17,596 lines
that aren't UTF-8, and 2 quoted paths, in 32 MB of diffs. The first run
took 128 s from the network for 93 of them; a run from the cache takes
under 10 s.

The API's limits, as observed, decide what can be listed:

- **The diff is refused** with `406` and `too_large` for a pull request
  of more than 300 files (TypeScript#28572, 434 files; kubernetes#141664,
  347; DefinitelyTyped#66535, 1,664; DefinitelyTyped#67332, 9,241), and for
  some of more than 20,000 lines (DefinitelyTyped#75174, 65,618 lines in
  131 files), though others far larger are served (TypeScript#64620,
  254,275 lines in 13 files). Refused pull requests can't be compared,
  so none is listed; if GitHub later refuses one, its case fails with
  GitHub's message.
- **The file list stops at 3,000 files**, which no servable diff reaches.
- **The file list leaves out a large file's patch**, but never its
  counts, the only part read here.
- **A binary file counts as zero** additions and deletions, which is
  what the test compares GitDiffKit's binary files as.

## Git settings that change the diff

Each was rendered from this repository's history (ce8bbbf..8f46c19) and
compared with `git diff --numstat` for the same commits, and the ones
the oracle tests can take are now among them:

| Setting | Result | Where it's tested now |
|---|---|---|
| `diff.noprefix` | Matches; paths keep their first directory | `GitApplyOracleTests`, against the plain diff (git apply would need `-p0`) |
| `diff.mnemonicPrefix` | Matches; only index and work-tree diffs change (`c/`, `i/`, `w/`) | The oracle's `--src-prefix=i/ --dst-prefix=w/` variant |
| `--relative=Sources` | Matches (44 files) | Not added: paths are relative to the subdirectory, which the tree checks don't allow |
| `--diff-algorithm=histogram` | Matches | A new `GitApplyOracleTests` variant |
| `--find-copies` | Matches | The sweep, and the oracle's `-M -C --find-copies-harder` variant |
| `color.ui=always` | Reads as no files and no damage | Documented, not tested: [A1](#a1-coloured-diffs) |

### A1: coloured diffs

With `color.ui=always` (or `--color=always`), every header line starts
with an SGR escape (`\e[1mdiff --git …`), so none is recognised: the
whole diff reads as preamble, with no files and no damage reported.
Steward already asks git for `--no-color`. Whether the library should
strip the escapes, report the input as damaged, or keep this behaviour
is a public API question. The maintainer's answer: document it now and
decide in step 5.1. So `DiffEventParser`, `Diff`, `DiffSummary` and
`ChangedLines` say a coloured diff reads as no files and no damage, and
to pass `--no-color`, as do Getting Started, the README and
INTERNALS.md; the behaviour is unchanged, and no test pins it.

## Platforms in CI

These run on every pull request and every push to `main`
([CI](../.github/workflows/ci.yml)). Run [40674641056](https://github.com/marosoaie/git-diff-parser/actions/runs/40674641056) is the first with all
of them:

| Check | Runner | Toolchain | Result |
|---|---|---|---|
| `tests-and-lint` | macos-26 | Xcode 26.6 (Swift 6.3.3) | `swift test` (186 tests) and `xcodebuild test` pass |
| `apple-platforms` (new) | macos-26 | Xcode 26.6 (Swift 6.3.3) | `xcodebuild build` for generic iOS, tvOS, watchOS and visionOS, warnings as errors |
| `linux-tests` | ubuntu-24.04 | `swift:6.2` (6.2.4), git 2.43.0 | 186 tests pass, a minute of fuzzing |
| `linux-arm64-tests` (new) | ubuntu-24.04-arm | `swift:6.2` (6.2.4), git 2.43.0 | 186 tests pass, a minute of fuzzing |
| `linux-jammy-tests` (new) | ubuntu-24.04 | `swift:6.2-jammy` (6.2.4) on Ubuntu 22.04, glibc 2.35, git 2.34.1 | 186 tests pass |
| `newest-swift-tests` (new) | ubuntu-24.04 | `swift:6.4.1-noble` (6.4.1), git 2.43.0 | 186 tests pass |

Ubuntu 22.04 is there for its glibc, older than 2.39, on which the
tests once didn't build (`memmem`, below). It doesn't fuzz: its
toolchain is `linux-tests`', so the minute would repeat that job's.

Swift 6.4.1 (2026-10-12) is the newest release, pinned to its exact
version so a new release changes CI only by a commit. It doesn't fuzz:
from Swift 6.4, SwiftPM builds with Swift Build, which keeps a target's
modules and objects under `out/` rather than `release/`, so the fuzz
recipe's paths don't hold there. The recipe moves when the floor does.

## Platforms tried once

From a temporary workflow on the branch `claude/step-5-0-a-platforms-once`,
never merged: runs [40655449255], [40660257843] and [40662552199].
Ubuntu 22.04 (`swift:6.2-jammy`) was tried there first, and passed once
the test support stopped using `memmem`; it is now a CI job.

| Platform | Runner and toolchain | Result |
|---|---|---|
| RHEL 9.8 (`swift:6.2-rhel-ubi9`) | ubuntu-24.04; Swift 6.2.4, git 2.52.0 | Builds with warnings as errors; 186 tests pass, once `diffutils` was installed for the plain `diff -ruN` test |
| macOS 26.6.2 on the Swift 6.2 floor | macos-26; Xcode 26.0.1 (Apple Swift 6.2, swiftlang-6.2.0.19.9), which the runner's `Xcode_26.0.app` is | `swift test` (186 tests) and `xcodebuild test` pass. Builds for the other Apple platforms couldn't run: the runner has their SDKs only for its default Xcode |
| Windows Server 2025 | windows-2025-vs2026; Swift 6.2.4 (compnerd/gha-setup-swift v0.5.1) | The library builds with warnings as errors, and the tests build; 158 tests pass and 25 fail, all in the test support, which runs git, xz and sh through `/usr/bin/env`, and in the documentation check, which reads paths with `/` |
| WebAssembly (WASI) | `swift:6.2.4-noble`; the swift-6.2.4-RELEASE_wasm Swift SDK | The library builds with warnings as errors; the tests don't, needing `Process`, `URLSession`, and atomic writes, which WASI's Foundation lacks |
| Static Linux SDK (musl) | `swift:6.2.4-noble`; the 0.1.0 static Linux Swift SDK for 6.2.4 | The library builds with warnings as errors; the tests don't, as the SDK has no swift-testing |

[40655449255]: https://github.com/marosoaie/git-diff-parser/actions/runs/40655449255
[40660257843]: https://github.com/marosoaie/git-diff-parser/actions/runs/40660257843
[40662552199]: https://github.com/marosoaie/git-diff-parser/actions/runs/40662552199

## Findings

Fixed in the test support:

- The test support's marker search used `memmem`, which glibc before 2.39
  (Ubuntu 22.04, RHEL 9), Windows and WASI don't declare, so the tests
  didn't build there; it uses `memchr` and `memcmp` now. The library was
  never affected. `linux-jammy-tests` builds against glibc 2.35 on
  every pull request, so a return fails CI.
- The sweep's `git show` runs failed with `EBADF` on Swift concurrency's
  threads, which drain no autorelease pool, until the test support's
  subprocess runner got a pool of its own on Darwin. The sweep is its
  check.

Intended, and explained above: the two differences of `git show`'s
reading, GitHub's refusals and its zero counts for binary files.

Documented, and open for step 5.1: [A1](#a1-coloured-diffs),
coloured diffs.

In the backlog:

- On Windows the test support runs commands through `/usr/bin/env`, and
  the documentation check reads paths with `/`, so the 25 tests that run
  git, xz or sh, or read the documents, fail there; the library and the
  tests build.
- SwiftPM 6.4's build layout breaks the fuzz recipe, as above.
