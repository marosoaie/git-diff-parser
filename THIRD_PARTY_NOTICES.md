# Third-party notices

git-diff-parser is MIT-licensed ([LICENSE](LICENSE)). One committed file
comes from another project and keeps its own licence:

| Path | Upstream | Licence | Notice |
|---|---|---|---|
| `Tests/GitDiffKitTests/Fixtures/swift-pr-70000.diff` | The diff of [swiftlang/swift#70000](https://github.com/swiftlang/swift/pull/70000), unmodified | Apache 2.0 with the Runtime Library Exception, Copyright (c) Apple Inc. and the Swift project authors | [`Tests/GitDiffKitTests/Fixtures/NOTICE`](Tests/GitDiffKitTests/Fixtures/NOTICE) |

The library itself takes no dependencies, and the fixture is a test
resource only: nothing third-party ships in `GitDiffKit`.

## Not listed

- **Downloaded fixtures.** The Linux kernel, redis, and
  swift-argument-parser diffs that the real-world tests read are
  downloaded and cached at test time, never committed.
- **The fuzzing corpus** (`Fuzz/Corpus`) is a handful of small diffs
  written for this project.
- **git** (GPL-2.0) is an oracle the tests run, never committed. The
  test helpers that render `git apply --summary` and `--numstat` output
  to compare against it are written for this project.
