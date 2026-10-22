# The layered diff model

**Status: draft for the maintainer's review (plan step 2.2).** Nothing here
is implemented yet. Steps 2.3–2.7 build on whatever this document settles,
so each section ends with a recommendation and its trade-offs, and the open
questions are collected in [Open questions](#open-questions). Claims that
decide a recommendation are backed by throwaway release-mode measurements,
described in [Measurements](#measurements).

## Decisions at a glance

| # | Topic | Recommendation | Alternatives considered |
|---|---|---|---|
| D1 | Event API shape | A generic parser over a consumer protocol with `mutating` callbacks: `DiffEventParser<Consumer: DiffEventConsumer>` | Stored closures; an `AsyncSequence` of events |
| D2 | Async | No `AsyncSequence` in 0.2. If one is added later, it yields whole files, never lines | Per-event `AsyncStream` (measured 170× slower) |
| D3 | `@inlinable` | Not up front. Measure again in 2.4 with a downstream consumer | Inline the whole hot path now |
| D4 | Header delivery | One `FileHeader` value per file, delivered once the extended headers are complete | One callback per extended header line |
| D5 | Line content payload | `Span<UInt8>`, passed as a bare callback parameter | `ArraySlice<UInt8>`; `String` |
| D6 | Paths | Raw bytes (`DiffPath`), with a lossy `String` view; `ChangedLines` keeps `String` keys | `String` everywhere, as today |
| D7 | CR and line cap | Strip `\r` but record it per line; keep the 1 MiB cap but flag truncated lines, and make the cap configurable | Keep `\r` in the content; drop the cap |
| D8 | Full-model storage | One byte arena per file, with lines as offsets into it | One `[UInt8]` per line |
| D9 | Combined diffs | Recognize and skip safely in 0.2: header parsed, `@@@` hunks consumed by their counts, no line events | Full N-parent line events now |
| D10 | `GIT binary patch` | Recognize, mark binary, keep the block's raw lines for round-tripping; don't decode | Decode base85 and inflate |
| D11 | Plain `diff -u` | Supported as today; paths reported as written, without git prefix stripping | Treat as unsupported |

## Context and constraints

The plan (Decisions, 2026-10-22) makes the library layered: a streaming
event API at the bottom, with collectors on top — `ChangedLines` (today's
result), a per-file summary, and the full diff with content. The Danger
replacement in swift-steward (phase 4) will consume the full model.

Every layer inherits the constraints in [AGENTS.md](../AGENTS.md) and
[INTERNALS.md](../INTERNALS.md):

- **Streaming and chunk-invariance.** Input arrives in chunks split
  anywhere. Results must be byte-for-byte identical for any chunking,
  tested down to 1-byte chunks.
- **Bytes first.** Hot paths scan `ArraySlice<UInt8>`; `String` is reached
  only after a cheap byte-level gate.
- **The budget.** About 0.2 s for the 70 MB kernel diff through the CLI,
  with flat peak memory (67 MB from 70 MB to 422 MB of input). Step 2.4
  gates on keeping it.
- **Hostile input.** Never trap; overflow-check arithmetic; damage stays
  inside one file; no throwing.
- **Value types only**, `Sendable` where honest, no dependencies, and from
  step 2.1 on no Foundation.
- **Oracles over hand-computed expectations**: `git apply --numstat` today,
  plus `--summary` and both numstat columns from step 2.3.

## What today's parser does

`DiffParser` (`Sources/GitDiffKit/DiffParser.swift`) is a single state
machine that records new-side line numbers of added lines. Grounding the
design in what it does and drops:

| Input | Today | Where |
|---|---|---|
| `diff ` line | Ends the current file (and a truncated hunk) | `DiffParser.swift:82`, `:100` |
| `--- ` / `+++ ` | Path taken from `+++` only; `a/`–`b/` (and `c/i/o/w`) stripped unless both sides use the same letter | `parseFileHeaderPath` |
| Quoted paths | Unquoted, then decoded as UTF-8 **lossily** (`String(decoding:)`) | `DiffParser.swift:321` |
| Tab trailer (`+++ b/x\t2026-…`) | Stripped | `DiffParser.swift:189` |
| Extended headers (`rename from`, `new file mode`, `index`, `similarity index`, …) | Ignored | – |
| Pure rename, mode-only change | No `+++` line, so no entry | – |
| `Binary files … differ` | Ends the file | `DiffParser.swift:82` |
| `GIT binary patch` | No `+++` line, so no entry; base85 lines can't look like headers (they start with a length letter `A–Z`/`a–z`) | measured below |
| `@@ -a,b +c,d @@ heading` | Counts parsed with overflow checks; the heading is dropped | `parseHunkHeader` |
| `@@@` (combined diff) | Not recognized: **the whole merge diff yields nothing**, and content such as `+++ resolved` is read as a file header (harmless today only because no `@@ ` follows) | measured below |
| `\ No newline at end of file` | Skipped | `DiffParser.swift:118` |
| Deleted and context lines | Counted for hunk budgets, not reported | `processHunkContentLine` |
| `\r` before `\n` | Stripped from every line, so CRLF diffs parse like LF ones | `ByteLineConsumer.swift:60` |
| Lines over 1 MiB | Processed truncated, uniformly | `ByteLineConsumer.swift:23` |

The real-world fixtures show what the model has to carry:

| Fixture | `diff --git` | New | Deleted | Renamed | Mode change | Binary | `\ No newline` | Hunks (with heading) |
|---|---|---|---|---|---|---|---|---|
| Linux 6.6→6.7 | 13,479 | 1,298 | 626 | 0 | 12 | 0 | 12 | 53,568 (45,022) |
| redis 7.0→7.2 | 1,133 | 218 | 21 | 8 | 0 | 0 | 25 | 6,138 (4,746) |
| swift-argument-parser 1.0→1.5 | 161 | 59 | 0 | 5 | 0 | 1 | 0 | 544 (437) |

None has CRLF lines or lines over 1 MiB (the kernel diff's longest is
1,393 bytes); 8,604 kernel lines contain non-ASCII bytes.

## 1. The event API

### Options

1. **A generic consumer struct with `mutating` callbacks** (recommended).
   The parser is `DiffEventParser<Consumer>` and owns its consumer by
   value; each event is a `mutating` method call. Collectors are plain
   structs, so they stay value types and are `Sendable` when their state
   is.
2. **Closures.** The parser stores `onFile`, `onHunk`, and `onLine`
   closures.
3. **An `AsyncSequence` of events**, as the primary API or as an adapter on
   top of 1.

### What the measurements say

On the kernel diff, release build, parse only (file already in memory, 4
MiB chunks; [M1](#m1-event-api-variants)):

| Variant | Time (min of 5 × 15) | Heap allocations |
|---|---|---|
| Today's `DiffParser` → `ChangedLines` | 85 ms | ≈ 94k |
| Generic consumer, `ChangedLines`-equivalent collector, not specialized | 88 ms | ≈ 42k |
| Same, specialized (`@inlinable` parser) | 96 ms | ≈ 42k |
| Generic consumer, counting collector, not specialized | 53 ms | ≈ 12.4k (one path `String` per file) |
| Same, specialized | 62 ms | ≈ 12.4k |
| Same, `Span<UInt8>` payload | 62 ms | ≈ 12.4k |
| Closures, counting | 57 ms | ≈ 12.4k (+2 boxes) |
| Owned events (`[UInt8]` copy per line), drained per chunk | 174 ms | ≈ 1.45M |
| `AsyncStream`, one element per event | 10,350 ms | ≈ 3.15M |

What decides it:

- **No variant allocates per event** except those that must own the
  payload. The generic parser allocates nothing per line whether or not
  it is specialized: the consumer lives inline in the parser, and an
  unspecialized call passes it by address through the witness table.
- **Specialization doesn't buy speed here.** The cost is dominated by the
  byte scan for `\n` and the classification, not the call. In this
  prototype the specialized build was consistently 8–18 % *slower* than
  the unspecialized one (stable across 5 interleaved process runs), most
  likely code layout; the measurement rules out "it must be inlinable to
  be fast", not more.
- **The event layer fits the 2.4 gate.** The `ChangedLines`-equivalent
  collector on the prototype runs within 4–13 % of today's parser, parse
  only; the gate is the CLI's 0.2 s including I/O and JSON.
- **Async per event is out of the question**: 170× the whole parse, plus an
  unbounded buffer when the consumer is slower than the producer. Even
  synchronous owned events cost 3× because each line becomes an
  allocation.

So speed doesn't separate options 1 and 2; semantics do:

- Closures that mutate captured state can't be `@Sendable` under Swift 6
  (capturing a `var` is an error), so a closure-holding parser is not
  `Sendable`, and the collector's state lives in captured boxes —
  reference semantics, against the value-types rule.
- A generic consumer composes: a `Pair<First, Second>` consumer runs
  `ChangedLines` and the summary in one pass with no erasure, and the
  library's own collectors live in the parser's module, so whole-module
  optimization specializes them regardless of D3.
- `Span` payloads (D5) can only be bare function parameters — they can't
  be stored, so they can't be enum payloads or `AsyncSequence` elements.
  That rules out events as values and fits callbacks of either kind.

### Recommendation (D1–D4)

```swift
/// Receives a diff's structure as it streams past.
public protocol DiffEventConsumer {
    /// A file's header block is complete (before its first hunk or binary data).
    mutating func beginFile(_ header: FileHeader)
    mutating func beginHunk(_ header: HunkHeader)
    /// One content line; `content` excludes the marker column and the terminator.
    mutating func line(_ line: LineInfo, content: Span<UInt8>)
    /// The previous line's side ends without a newline (`\ No newline at end of file`).
    mutating func noNewlineAtEndOfFile()
    /// One raw line of a `GIT binary patch` block (D10).
    mutating func binaryPatchLine(_ content: Span<UInt8>)
    mutating func endFile()
    /// A line outside any file: a commit message, mail headers, junk.
    mutating func unrecognizedLine(_ content: Span<UInt8>)
}
// Empty default implementations, so a collector implements only what it needs.

public struct DiffEventParser<Consumer: DiffEventConsumer> {
    public var consumer: Consumer
    public init(consumer: Consumer, options: ParsingOptions = .init())
    public mutating func consume(_ chunk: ArraySlice<UInt8>)   // + [UInt8], String
    public mutating func finalize() -> Consumer
}
extension DiffEventParser: Sendable where Consumer: Sendable {}

public struct LineInfo: Sendable, Equatable {
    public var kind: Kind                  // .context, .addition, .deletion
    public var oldNumber: Int?             // nil for additions
    public var newNumber: Int?             // nil for deletions
    public var endsWithCarriageReturn: Bool   // D7
    public var isTruncated: Bool              // D7
}
```

- **Ordering contract**: `beginFile` (`beginHunk` `line`* )* or
  `binaryPatchLine`*, then `endFile`; `unrecognizedLine` only between
  files. `noNewlineAtEndOfFile` only directly after a `line`. Every
  `beginFile` gets its `endFile`, including at `finalize()` and when a
  damaged file is abandoned, so collectors never track boundaries
  themselves.
- **D4, one header value per file**: extended headers arrive as separate
  lines but mean something only together (a rename is `rename from` +
  `rename to` + `similarity index`). Buffering them is cheap (a handful of
  short lines per file), so the parser assembles a `FileHeader` and
  delivers it at the first `@@`, binary marker, next file, or end of input.
  A file with no hunks (pure rename, mode change) still gets
  `beginFile`/`endFile`.
- **Keeping today's API**: `DiffParser` and `ChangedLines(diff:)` stay as
  a facade over `DiffEventParser<ChangedLines.Collector>`, so 0.1 callers
  don't break. Whether to rename or retire the facade is for step 5.1.
- **D2**: no `AsyncSequence` in 0.2. Callers with an async byte source
  call `consume(_:)` inside their own `for await` loop. If one is added
  later, it should yield owned `DiffFile` values (one per file, ~12k for
  the kernel), never lines.
- **D3**: don't mark the parser `@inlinable` up front. It would turn its
  internals into `@usableFromInline` API surface for no measured gain.
  Revisit in 2.4 with Steward's consumer if a profile says otherwise.

## 2. The model

### Files

```swift
public struct FileHeader: Sendable, Equatable {
    public var format: Format          // .git, .combined(parents: Int), .unified
    public var change: Change          // see the table below
    public var oldPath: DiffPath?      // nil for a creation (/dev/null)
    public var newPath: DiffPath?      // nil for a deletion
    public var oldMode: FileMode?
    public var newMode: FileMode?
    public var oldObjectID: [UInt8]?   // abbreviated hashes from the index line, as written
    public var newObjectID: [UInt8]?
    public var isBinary: Bool
    public var rawLines: [UInt8]       // the header block verbatim, for round-tripping (2.6)
}

public enum Change: Sendable, Equatable {
    case added, deleted, modified
    case renamed(similarity: Int?)     // percent; nil if the header omitted it
    case copied(similarity: Int?)
}

public struct FileMode: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt32        // parsed from octal with overflow checks
    public static let regular = FileMode(rawValue: 0o100644)
    public static let executable = FileMode(rawValue: 0o100755)
    public static let symlink = FileMode(rawValue: 0o120000)
    public static let gitlink = FileMode(rawValue: 0o160000)   // submodule
}
```

How the plan's statuses map, with the oracle for each (step 2.3):

| Status | Signalled by | Model | `git apply --summary` |
|---|---|---|---|
| Added | `new file mode M`, `--- /dev/null` | `.added`, `newMode` | `create mode M path` |
| Deleted | `deleted file mode M`, `+++ /dev/null` | `.deleted`, `oldMode` | `delete mode M path` |
| Modified | anything else | `.modified` | – |
| Renamed | `similarity index N%`, `rename from/to` | `.renamed(similarity: N)` | `rename a => b (N%)` |
| Copied | `similarity index N%`, `copy from/to` | `.copied(similarity: N)` | `copy a => b (N%)` |
| Mode change | `old mode`/`new mode` | `oldMode != newMode` (computed `modeChanged`) | `mode change A => B path` |
| Binary | `Binary files … differ`, `GIT binary patch` | `isBinary` | numstat `-  -` |
| Rewrite (`-B`) | `dissimilarity index N%` | an extra `dissimilarity: Int?` | `rewrite path (N%)` |

Change kind, mode change, and binary are orthogonal — a rename can also
change content and mode — so they are separate properties rather than one
enum. A type change (file ↔ symlink) needs no case of its own: git emits it
as a deletion followed by a creation of the same path (to confirm with a
fixture in 2.3).

**Paths.** Where a path comes from matters, because `diff --git a/x b/y` is
ambiguous when paths contain spaces and aren't quoted:

1. `rename from`/`to` and `copy from`/`to` are authoritative for renames
   and copies.
2. Otherwise `---`/`+++`, which today's parser already handles.
3. Otherwise (mode-only change, binary file without rename) the
   `diff --git` line, split the way `git apply` does it: with no rename,
   both names are equal, so the split is where `a/X b/X` matches.

### Paths as bytes (D6)

Git paths are bytes. With `core.quotePath` (the default), git quotes
non-ASCII bytes as octal escapes, and a repository with Latin-1 file names
yields invalid UTF-8 after unquoting. Today `unquote` decodes lossily, so
two such paths can collapse into one, and the full model couldn't render
the input back (2.6).

**Recommendation:** `DiffPath` stores the unquoted bytes and offers
`description`/`string` (lossy decoding, documented at the declaration) and
`==` on bytes. `ChangedLines` keeps `String` keys — every consumer today
uses them, and lossy decoding there only matters for invalid-UTF-8 paths.
*Trade-off:* one more type for callers of the full model to learn, versus
a model that can't represent every real repository.

### Hunks

```swift
public struct HunkHeader: Sendable, Equatable {
    public var oldStart: Int, oldCount: Int
    public var newStart: Int, newCount: Int
    public var heading: [UInt8]   // text after the closing @@ (git's funcname), may be empty
    public var rawLine: [UInt8]   // `@@ -1 +1 @@` and `@@ -1,1 +1,1 @@` mean the same; keep the spelling
}
```

The counts keep today's checks (`maxLineNumber = 1 << 48`, checked
accumulation). The heading is the section name git found (`@@ -2,4 +2,4 @@
one` in the measured binary fixture); 84 % of kernel hunks have one. It is
kept as bytes, since it is file content.

### Lines

`LineInfo` (above) carries kind, old/new numbers, and two flags; the
content is the event's `Span`. In the full model:

```swift
public struct DiffLine: Sendable, Equatable {
    public var info: LineInfo
    public var content: ArraySlice<UInt8>    // a view into the file's arena (D8)
    public var hasNoNewlineAtEnd: Bool       // from the following `\` line
}
```

`\ No newline at end of file` is its own event because it follows the
line it modifies; attaching it to the line event would need one line of
lookahead, which means copying lines that straddle chunks. Its text is
not checked beyond the leading `\`, as today, because GNU diff localizes
it.

### Collectors

- **`ChangedLines`**: semantics unchanged (new-side added lines, deleted
  and binary files absent, renamed files under their new path), re-built
  on events in 2.4. Gate: identical results on every fixture and
  chunking.
- **Summary** (2.5): one entry per file — `FileHeader` plus added and
  deleted counts. Memory grows with the file count, not the content.
  Oracle: both `--numstat` columns and `--summary`.
- **Full model** (2.5): `Diff { files: [DiffFile] }`, where `DiffFile`
  holds the header, hunks, and lines. Memory grows with the diff's
  content; see D8.

## 3. Content: bytes, String, or Span

### Bytes or String

Line content is file content, so it can be any encoding. Decoding every
line to `String` costs 1.6× the whole parse (100 ms vs 62 ms for the
counting consumer) and one allocation per line over 15 bytes (≈ 1.14M on
the kernel diff), and it is lossy for non-UTF-8 files.
**Recommendation:** bytes in the events and the model; decoding is the
consumer's choice, through a documented convenience (below).

### `Span<UInt8>` for zero-copy payloads (D5)

Measured on Swift 6.4 (macOS SDK 27) with a macOS 14 deployment target,
and on Swift 6.2.4 in the official `swift:6.2` Linux image
([M2](#m2-span-on-swift-62-and-64)):

- **Works:** `Span<UInt8>` as a protocol requirement's parameter, through
  a generic parser, specialized or not; on both compilers and both
  platforms. Same speed as `ArraySlice` (62 ms both).
- **Enforced by the compiler, on both versions:** a consumer can't store
  the span, return it, capture it in an escaping position, put it in an
  enum payload, use it as an `AsyncSequence` element, or wrap it in a
  `~Escapable` struct (that needs the experimental lifetime features).
- **Availability:** `ArraySlice.span` compiles for macOS 14, which is all
  the parser needs (its carry buffer is an array it slices). `Array.span`
  and `UTF8Span` need macOS 26.
- **Friction:** `Span` isn't a `Sequence` in 6.2, so no `map`/`filter`,
  and there is no `Array(span)`. Copying out takes an index loop or
  `withUnsafeBufferPointer`, which needs `unsafe` under
  `strictMemorySafety()` (and Swift 6.4 warns that one of those `unsafe`
  markers is unnecessary, so warning-free on both compilers needs care).
- **Not verified:** running on macOS earlier than 26. The measurements ran
  on macOS 26, where `Span` is in the OS. The build succeeds for macOS
  14, but whether the back-deployed `Span` runs there needs a CI job on a
  `macos-14` or `macos-15` runner.

The case for `Span` over `ArraySlice` is safety, not speed: an
`ArraySlice` payload can be stored, and storing it silently keeps the
whole 4 MiB input chunk alive. A collector that kept a slice per line
would retain the entire input — exactly the "streaming silently degrades
to whole-file memory" failure INTERNALS.md warns about, with no compiler
help. `Span` makes that impossible. It also decouples the API from the
parser's buffer type.

**Recommendation:** `Span<UInt8>`, with the library shipping the copy-out
conveniences so consumers never write `unsafe`:
`Array(copying: Span<UInt8>)` and `String(decodingLossily: Span<UInt8>)`
(names open), implemented once with a justified `unsafe`.
*Trade-offs:* more awkward to consume than a slice; adds the runtime
verification above; pins the callback style (D1) because spans can't be
values.

### Carriage returns and the 1 MiB cap (D7)

Both of today's normalizations are invisible to `ChangedLines`, but the
full model and the round-trip property (2.6) can't hide them:

- **`\r`.** A CRLF file's content lines end in `\r\n` inside the diff;
  stripping the `\r` changes the content and breaks round-tripping, while
  keeping it would break header matching for diffs that went through a
  CRLF transport. **Recommendation:** keep stripping (headers and
  `ChangedLines` behave exactly as today) and record it as
  `LineInfo.endsWithCarriageReturn`, so the model can render it back.
- **1 MiB cap.** Minified and generated files do have megabyte lines.
  **Recommendation:** keep the cap as the default (it bounds the carry
  buffer for every collector, and content-blind collectors are unaffected),
  report `isTruncated` so truncation is never silent, and make it a
  `ParsingOptions.maximumLineLength`. The full-model collector's
  convenience initializer raises it, since that collector's memory grows
  with content anyway. Round-trip tests run with the cap raised.

### Full-model storage (D8)

Retaining every line of the kernel diff ([M3](#m3-full-model-memory)):

| Layout | Time | Heap allocations | Peak RSS (input itself ≈ 80 MB) |
|---|---|---|---|
| Events only, nothing retained | 62 ms | ≈ 12.4k | 80 MB |
| One `[UInt8]` per line | 149 ms | ≈ 1.45M | 358 MB |
| One byte arena per file, lines as offsets | 101 ms | ≈ 175k | 259 MB |

**Recommendation:** per-file arenas; a `DiffLine` exposes its content as a
slice of the arena. The prototype's line record is 40 bytes (1.6M lines =
65 MB); 32-bit offsets would shrink it, at the cost of a per-file 4 GiB
limit to check. 2.5 documents the result: the full model takes about 2.5×
the diff's size.

## 4. Special inputs

### Combined diffs (`diff --cc`, `@@@`) (D9)

`git show <merge>` and `git log -p --cc` print combined diffs: one
`diff --cc path` per file, `index a,b..c`, `mode a,b..c`, hunk headers with
N+1 `@` and N+1 ranges for N parents, and N marker columns per line. The
measured merge ([M4](#m4-special-inputs-against-todays-parser)) shows the
problem today:

```text
diff --cc list.md
@@@ -1,5 -1,5 +1,5 @@@
  one
- two
+ + side item
  three
--four
 -five
+++ resolved
 ++ main item
```

Today this yields no lines at all, and `+++ resolved` — a line added
relative to both parents whose content is `+ resolved` — is taken for a
file header.

Options: (a) recognize and skip safely; (b) full support, with per-parent
marker columns on line events.

**Recommendation (a) for 0.2:** parse the header into
`FileHeader(format: .combined(parents: N))` (new-side path and modes),
consume `@@@` hunks by counting their declared ranges, and emit no line
events. The counting rule, checked against the example: a line with no
`-` column is in the result and uses the new side's budget, plus parent
*i*'s budget wherever column *i* is a space; a line with a `-` column is
not in the result and uses parent *i*'s budget only where column *i* is
`-`. `ChangedLines` stays
empty for merges, but deliberately and documented, pointing callers to
`--diff-merges=first-parent` or a three-dot diff (measured: the
first-parent diff of the same merge yields lines 2 and 4).
*Trade-off:* "what did the merge resolution add" (lines marked `++`)
can't be answered yet. Nothing in the plan needs it; Danger diffs
`base...head`. The design leaves room: a later `combinedLine` event can
carry the marker columns.

### `GIT binary patch` (D10)

With `--binary`, git replaces `Binary files … differ` with:

```text
GIT binary patch
literal 8
PcmeAS@N;M2<X{H?3F!fc

literal 7
OcmeAS@N;KiWC8#POaXEL
```

A forward block, then a reverse one (for `git apply -R`). Each is
`literal <size>` or `delta <size>`, base85 lines whose first character
encodes the line's byte count, and a blank line. The data is
zlib-deflated.

**Recommendation:** mark `isBinary`, parse the `literal`/`delta` sizes
(overflow-checked) into the summary, and pass every line to
`binaryPatchLine` so the full model can keep the block verbatim for
round-tripping. **Don't decode**: inflating zlib without dependencies
means hand-writing a decompressor that has to survive hostile input, for
a feature no planned consumer needs. Today's behavior (no entry, the next
file parses normally) was confirmed on a real `--binary` diff.

### Plain `diff -u` (D11)

GNU/BSD `diff -u` and `diff -ruN` output works today
([M4](#m4-special-inputs-against-todays-parser)): the tab-separated
timestamps are stripped, and `diff -ruN old new` yields `new/f.txt` and
`new/added.txt`. Differences from git output that the model must absorb:

- No extended headers, so the status comes from `/dev/null` alone; with
  `-N`, an absent file is shown with an epoch timestamp instead of
  `/dev/null`. Timestamps are locale- and implementation-specific, so
  don't infer creation from them: such files are `.modified`.
- Paths carry the compared directories (`old/`, `new/`), not git's `a/`
  `b/`. Report them as written (`format: .unified`, no git prefix
  heuristics), and offer `DiffPath.droppingLeadingComponents(_:)` for
  `patch -p1` style stripping.
- `diff -r` prints `Only in old: x` for unpaired files without `-N`; those
  are `unrecognizedLine`s.
- A single-file `diff -u a b` has no `diff ` line; the `--- `/`+++ ` pair
  starts the file, as today.

## Hostile input in the new parsing

Step 2.7's mutation tests cover all of this, but the design has to allow
it:

- Extended headers are recognized only in the header state, between a
  `diff ` line and the first `@@`. Content can never be mistaken for one,
  and vice versa — the combined-diff `+++ resolved` case shows why state
  matters.
- Every number (modes, similarity, sizes, combined ranges) uses the
  checked digit scanner with a cap; similarity is clamped to 0–100.
- The header buffer is bounded (a line count and the line cap), so a
  stream of junk header lines can't grow memory.
- `diff --git` splitting, quoted-path unquoting, and `rename from/to`
  parsing degrade to "unknown path" rather than trapping.

## Open questions

For the maintainer; each names the decision it affects.

1. **D1/naming.** `DiffEventParser` / `DiffEventConsumer`, and keep
   `DiffParser` as the `ChangedLines` facade until 5.1? Other names for
   the full model (`Diff`, `DiffFile`, `DiffLine`) and the summary
   (`DiffSummary`)?
2. **D5.** Is `Span` worth its friction, given the macOS < 26 runtime
   check still to do? The fallback is `ArraySlice` with a documented
   "don't store this" warning.
3. **D6.** Bytes for paths in the full model while `ChangedLines` keeps
   `String`: acceptable split?
4. **D7.** Should the full-model collector raise the line cap to unlimited,
   or to a large finite value (say 64 MiB)?
5. **D9.** Is "combined diffs yield no lines, deliberately" acceptable for
   0.2, or should `ChangedLines` report the lines a merge resolution adds?
6. **Damage reporting.** Should there be a `recoveredFromMalformedInput()`
   event (no-op by default)? It would let 2.7 assert "damage stays inside
   one file" directly, and let tools warn users.
7. **Platforms.** Step 2.1 widens `platforms:`. If the floor rises to
   macOS 26 for other reasons, `UTF8Span` and `Array.span` become usable
   and the conveniences in D5 get simpler.

## Measurements

All throwaway: the harness isn't part of this PR. A copy is in the
coordinator's shared notes folder (`2.2-measurements/`), so it can be
re-run.

**Setup.** Apple M4, macOS 26, Swift 6.4 (Xcode 27; the package's floor is
6.2, which isn't installed locally), `swift build -c release`, the
package's strict settings, macOS 14 deployment target. Input: the cached
`linux-6.6-to-6.7.diff` (73.8 MB), read whole, fed in 4 MiB slices.
Allocations counted with a `DYLD_INSERT_LIBRARIES` interposer on the
`malloc` family; its sanity check counts 2 calls per Swift object
allocation (2,007 for 1,000 objects), so the tables report raw counts
halved.

### M1: event API variants

A prototype event parser (line splitting, hunk counting, `+++` paths)
generic over a consumer, built three ways: plain (cross-module calls stay
unspecialized — confirmed with `nm`: no specializations of `ProtoPlain`),
`@inlinable` (specializations present for every consumer), and
`@inlinable` with a `Span` payload. Consumers live in the executable, so
specialization has to cross a module boundary, as for a real client.

```sh
swift build -c release
DYLD_INSERT_LIBRARIES=…/libcount.dylib .build/release/bench linux-6.6-to-6.7.diff
for i in 1 2 3 4 5; do for v in A- B- C- D- E- F- G- K-; do
  .build/release/bench linux-6.6-to-6.7.diff $v; done; done   # timing, no interposer
```

| Variant | min | median | raw allocator calls |
|---|---|---|---|
| A: today's `DiffParser` | 84.8 ms | 85.9 ms | 187,828 |
| B: generic, unspecialized, counting | 52.7 ms | 52.8 ms | 24,860 |
| C: generic, specialized, counting | 62.0 ms | 62.1 ms | 24,860 |
| D: as C, `Span` payload | 61.9 ms | 62.5 ms | 24,860 |
| E: specialized, `ChangedLines` collector | 95.6 ms | 96.6 ms | 84,648 |
| F: unspecialized, `ChangedLines` collector | 88.2 ms | 89.3 ms | 84,640 |
| G: closures, counting | 56.8 ms | 57.4 ms | 24,864 |
| H: owned events, drained per chunk | 174 ms | – | 2,900,850 |
| I: `AsyncStream`, per event | 10,353 ms | – | 6,302,494 |
| K: decode every line to `String` | 99.8 ms | 100.1 ms | 2,284,694 |

E and F produce a `ChangedLines` equal (`==`) to today's parser on the
kernel diff. All counting variants report the same 1,633,764 lines. An
earlier single run had C faster than B (47 vs 55 ms); the interleaved runs
above reversed that consistently, so the doc claims only "no meaningful
difference, no allocations either way".

### M2: `Span` on Swift 6.2 and 6.4

Probe files compiled with `swiftc -swift-version 6 -emit-sil` (lifetime
errors are diagnosed in SIL, so `-typecheck` misses them), on Swift 6.4 for
`arm64-apple-macos14` and `arm64-apple-macos26`, and in
`docker run swift:6.2` (Swift 6.2.4, Linux):

| Probe | 6.4, macOS 14 target | 6.4, macOS 26 target | 6.2.4, Linux |
|---|---|---|---|
| `Span` parameter in a protocol requirement, generic parser, runs | ✅ | ✅ | ✅ |
| `ArraySlice.span` | ✅ | ✅ | ✅ |
| `Array.span` | ❌ macOS 26 only | ✅ | ✅ |
| `UTF8Span(validating:)`, `String(copying:)` | ❌ macOS 26 only | ✅ | not probed |
| Stored property of type `Span` | ❌ | ❌ | ❌ |
| `~Escapable` struct holding a `Span` | ❌ (needs lifetime features) | ❌ | ❌ |
| Function returning `Span` | ❌ | ❌ | ❌ |
| Enum payload / `AsyncStream<Span<UInt8>>` | ❌ | ❌ | ❌ |
| Assigning a closure's `Span` argument to an outer variable | ❌ | ❌ | ❌ |
| `Array(span)` | ❌ no such initializer | ❌ | ❌ |
| Passing `line.dropFirst().span` directly | ❌ escapes a temporary; bind the slice first | – | – |

### M3: full-model memory

```sh
for v in A-baseline C-generic J1 J2; do /usr/bin/time -l .build/release/bench linux-6.6-to-6.7.diff $v; done
```

Peak RSS: A 88 MB, C 80 MB, J1 (per-line arrays) 358 MB, J2 (per-file
arena) 259 MB. Single runs; the input buffer accounts for ≈ 74 MB of each.

### M4: special inputs against today's parser

A scratch repository with a merge (`git merge --no-commit`, edited
resolution), a binary file changed with `--binary`, and
`diff -ruN old new`, each fed to today's `DiffParser`:

| Input | Today's `ChangedLines` |
|---|---|
| `git show --cc <merge>` | empty |
| `git show --diff-merges=first-parent <merge>` | `list.md: [2...2, 4...4]` |
| `git diff --binary` (binary + text file) | `list.md: [5...5]`; `git apply --numstat` shows `-  -  img.bin` |
| `diff -ruN old new` | `new/added.txt: [1...1]`, `new/f.txt: [2...2]` |
| CRLF diff | identical to LF |
