# Dangerfile

This repository's own pull request checks, run by
[Steward](https://github.com/marosoaie/swift-steward) through
[steward-action](https://github.com/marosoaie/steward-action) in
[ci.yml](../.github/workflows/ci.yml)'s `tests-and-lint` job. The rules are
in [`Sources/Dangerfile/Checks.swift`](Sources/Dangerfile/Checks.swift), and
their tests in [`Tests/DangerfileTests`](Tests/DangerfileTests).

It's a package of its own, beside GitDiffKit's: GitDiffKit's
`Package.swift` never names it, so the library still has no dependencies,
and its users never fetch Steward. It depends on swift-steward's `main`
branch at the revision `Package.resolved` pins, as Steward's
[quickstart](https://github.com/marosoaie/swift-steward/blob/main/docs/quickstart.md)
sets a Dangerfile up; `swift package update --package-path Dangerfile`
moves the pin.

From the repository's root:

```sh
swift test --package-path Dangerfile   # the rules' tests
swift build 2>&1 | tee build.log && swiftlint lint --quiet | tee swiftlint.log
swift run --package-path Dangerfile    # a dry run on this branch: prints the summary, posts nothing
```

The diagnostics rule reads `build.log` and `swiftlint.log` at the
repository's root, as the job writes them, and a missing one is a failure.
