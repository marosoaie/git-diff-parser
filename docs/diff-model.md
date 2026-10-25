# The layered diff model

**Status: reviewed (plan step 2.2).** The maintainer answered the open
questions on 2026-10-25; [Answered questions](#answered-questions) records
the answers, and the recommendations below are updated to match. Steps
2.3–2.7 build on what this document settles, so each section ends with a
recommendation and its trade-offs. Claims that
decide a recommendation are backed by throwaway release-mode measurements,
described in [Measurements](#measurements).

## Decisions at a glance

| # | Topic | Recommendation | Alternatives considered |
|---|---|---|---|
| D1 | Event API shape | A generic parser over a consumer protocol with `mutating` callbacks: `DiffEventParser<Consumer: DiffEventConsumer>` | Stored closures; an `AsyncSequence` of events |
| D2 | Async | No `AsyncSequence` in 0.2. If one is added later, it yields whole files, never lines | Per-event `AsyncStream` (measured 170× slower) |
| D3 | `@inlinable` | Not up front. Measure again in 2.4 with a downstream consumer | Inline the whole hot path now |
| D4 | Header delivery | One `FileHeader` value per file, delivered once the extended headers are complete; no heap allocation per hunk | One callback per extended header line |
| D5 | Line content payload | `Span<UInt8>`, passed as a bare callback parameter; platform floors at the 26 releases | `ArraySlice<UInt8>`; `String` |
| D6 | Paths | Raw bytes (`DiffPath`), with a lossy `String` view; `ChangedLines` keeps `String` keys | `String` everywhere, as today |
| D7 | CR and line cap | Strip `\r` but record it per line; keep the 1 MiB cap but flag truncated lines, and make the cap configurable; the full model raises it to 64 MiB | Keep `\r` in the content; drop the cap |
| D8 | Full-model storage | One byte arena per file, with lines as offsets into it | One `[UInt8]` per line |
| D9 | Combined diffs | Recognize (`diff --cc` and `diff --combined`) and skip safely in 0.2: result-side header parsed, `@@@` hunks consumed by their counts, no line events; the skip is documented | Full N-parent line events now |
| D10 | `GIT binary patch` | Recognize, mark binary, keep the block's raw lines for round-tripping; don't decode | Decode base85 and inflate |
| D11 | Plain `diff -u` | Supported as today, including today's prefix heuristic; epoch timestamps mean `/dev/null`, as in `git apply` | Treat as unsupported |

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
- **The event layer probably fits the 2.4 gate, but M1 is a lower
  bound.** The `ChangedLines`-equivalent collector on the prototype runs
  within 4–13 % of today's parser, parse only; the library's own facade
  is specialized by whole-module optimization, so variant E (+13 %) is
  the relevant one. The prototype builds no `FileHeader`, buffers no
  extended headers, and records no flags, so the real parser will cost
  more. The sketch below is shaped to keep that extra cost per file, not
  per hunk or line: on the kernel diff that is 13.5k files against 53.6k
  hunks and 1.6M lines. The gate is the CLI's 0.2 s including I/O and
  JSON, and 2.4 re-measures it.
- **Async per event is out of the question**: 170× the whole parse, plus an
  unbounded buffer when the consumer is slower than the producer. Even
  synchronous owned events cost 3× because each line becomes an
  allocation.

So speed doesn't separate options 1 and 2; semantics do:

- The usual closure style — closures that mutate captured state — can't
  be `@Sendable` under Swift 6 (capturing a `var` is an error), so the
  parser isn't `Sendable`, and the state lives in captured boxes:
  reference semantics, against the value-types rule.
- Closures that take `(inout State, …)` and capture nothing avoid both
  problems. But that is option 1 with closures instead of methods: the
  parser is still generic over `State`, and the closures add nothing
  except an extra indirection. It can be offered later as one ready-made
  consumer (`ClosureConsumer<State>`) on top of option 1.
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
    /// `rawHeader` is the block verbatim, `\r` included, for round-tripping.
    mutating func beginFile(_ header: FileHeader, rawHeader: Span<UInt8>)
    /// A hunk starts; `heading` is the text after the closing `@@`.
    mutating func beginHunk(_ header: HunkHeader, heading: Span<UInt8>)
    /// One content line; `content` excludes the marker column and the terminator.
    mutating func line(_ line: LineInfo, content: Span<UInt8>)
    /// The previous line's side ends without a newline (`\ No newline at end of file`).
    mutating func noNewlineAtEndOfFile()
    /// One raw line of a `GIT binary patch` block (D10), after the marker line.
    mutating func binaryPatchLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool)
    /// The current file is over: the next file starts, input ends, or the file is abandoned as damaged.
    mutating func endFile()
    /// A line that is neither header nor hunk content: a commit message, mail headers, `Only in …`, junk.
    mutating func unrecognizedLine(_ content: Span<UInt8>, endsWithCarriageReturn: Bool)
    /// Input was damaged: `.info` for a local recovery, `.error` for an abandoned file (Q6).
    mutating func damage(_ report: DamageReport)
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

- **Ordering contract**: `beginFile`, then hunks (`beginHunk` followed
  by `line`s) or `binaryPatchLine`s, then `endFile`.
  `noNewlineAtEndOfFile` comes only directly after a `line`.
  `unrecognizedLine` can come before the first file, between files, and
  inside a file between hunks or after the last one (a `git log -p`
  commit header, a `-- ` signature, `Only in …`): the parser can't know
  which file such a line "belongs" to, so it reports its position and
  the full model keeps it there.
- **When a file ends**: `endFile` fires when the next file starts (a
  `diff ` line; or, in plain `diff -u` output that has no `diff ` lines,
  a `--- `/`+++ ` pair after the current file's hunks), at `finalize()`,
  and when a damaged file is abandoned. Every
  `beginFile` gets its `endFile`, so collectors never track boundaries
  themselves.
- **No heap allocation per hunk or line.** The hunk heading and the raw
  header block are spans of the parser's own buffers, and `HunkHeader`
  and `LineInfo` are plain integers and flags. A collector that ignores
  them pays nothing. Per file, the `FileHeader`'s paths are the only
  allocations (today's parser makes one `String` per file too); object
  IDs are stored inline (hex-decoded, they fit in 32 bytes).
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
  later, it should yield owned `DiffFile` values (one per file, 13.5k for
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
    public var oldObjectID: ObjectID?  // from the index line: abbreviated, or full with --binary/--full-index
    public var newObjectID: ObjectID?
    public var dissimilarity: Int?     // percent, for rewrites (-B)
    public var isBinary: Bool
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

/// A hex object ID as written (abbreviated or full, SHA-1 or SHA-256),
/// decoded to at most 32 bytes stored inline, so it never allocates.
public struct ObjectID: Sendable, Hashable { /* inline bytes + hex length */ }
```

How the plan's statuses map, with the oracle for each (step 2.3):

| Status | Signalled by | Model | `git apply --summary` |
|---|---|---|---|
| Added | `new file mode M`, `--- /dev/null` | `.added`, `newMode` | `create mode M path` |
| Deleted | `deleted file mode M`, `+++ /dev/null` | `.deleted`, `oldMode` | `delete mode M path` |
| Modified | anything else | `.modified` | – |
| Renamed | `similarity index N%`, `rename from/to` | `.renamed(similarity: N)` | `rename a => b (N%)` |
| Copied | `similarity index N%`, `copy from/to` | `.copied(similarity: N)` | `copy a => b (N%)` |
| Mode change | `old mode`/`new mode` | computed `modeChanged`: both modes known and different (an add or delete is not a mode change) | `mode change A => B path` |
| Binary | `Binary files … differ`, `GIT binary patch` | `isBinary` | numstat `-  -` |
| Rewrite (`-B`) | `dissimilarity index N%` | `dissimilarity` | `rewrite path (N%)` |

For an ordinary modification, the mode appears only as the trailer of
the `index` line (`index 587be6b..5f5521f 100644`); the parser sets
`oldMode` and `newMode` from it.

Change kind, mode change, and binary are orthogonal — a rename can also
change content and mode — so they are separate properties rather than one
enum. A type change (file ↔ symlink) needs no case of its own: git emits it
as a deletion followed by a creation of the same path (confirmed in 2.3 on
a fast-import fixture, where `git apply --summary` reads it the same way).

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
`ChangedLines` documents that its `String` keys compare by Unicode
canonical equivalence, so the NFC and NFD spellings of one name, which git
treats as two paths, share a key.
*Trade-off:* one more type for callers of the full model to learn, versus
a model that can't represent every real repository.

### Hunks

```swift
public struct HunkHeader: Sendable, Equatable {
    public var oldStart: Int, oldCount: Int
    public var newStart: Int, newCount: Int
    public var oldCountIsImplicit: Bool   // `@@ -1 +1 @@` vs `@@ -1,1 +1,1 @@`: same meaning,
    public var newCountIsImplicit: Bool   // kept so the header renders back as written
}
```

The counts keep today's checks (`maxLineNumber = 1 << 48`, checked
accumulation). The heading is the section name git found (`@@ -2,4 +2,4 @@
one` in the measured binary fixture); 84 % of kernel hunks have one. It is
bytes, since it is file content, and arrives as a `Span` with
`beginHunk`; the full model copies it into the file's arena.

### Lines

`LineInfo` (above) carries kind, old/new numbers, and two flags; the
content is the event's `Span`. In the full model:

```swift
public struct DiffLine: Sendable, Equatable {
    public var info: LineInfo
    public var hasNoNewlineAtEnd: Bool       // from the following `\` line
    var contentRange: Range<Int32>           // offsets into the file's arena (D8)
}
// DiffFile exposes `content(of: DiffLine) -> ArraySlice<UInt8>`; storing a
// slice per line would retain the arena once per line and double the record.
```

`\ No newline at end of file` is its own event because it follows the
line it modifies; attaching it to the line event would need one line of
lookahead, which means copying lines that straddle chunks. Its text is
not checked beyond the leading `\`, as today, because GNU diff localizes
it; a localized marker therefore renders back in English, one of the
round-trip exclusions below.

### Collectors

- **`ChangedLines`**: semantics unchanged (new-side added lines, deleted
  and binary files absent, renamed files under their new path), re-built
  on events in 2.4. Gate: identical results on every fixture and
  chunking.
- **Summary** (2.5): one entry per file — `FileHeader` plus added and
  deleted counts. Memory grows with the file count, not the content.
  Oracle: both `--numstat` columns and `--summary`.
- **Full model** (2.5): `Diff { files: [DiffFile] }`, where `DiffFile`
  holds the header, its raw header bytes, hunks, lines, binary patch
  lines, and the unrecognized lines at their positions; `Diff` also
  keeps the lines before the first file (a `git show` commit header).
  Memory grows with the diff's content; see D8.

**Round-trip (2.6) needs every byte to land somewhere.** With the design
above, it does: header blocks (including `Binary files … differ` and
`GIT binary patch` marker lines) are kept raw, `\r` included; content
lines keep their CR flag; unrecognized lines keep their position and CR
flag; hunk headers keep their spelling. The property is defined as
byte-identical for git's own output, and excludes, by design:

- combined diffs (D9 keeps no content for them);
- lines truncated by the cap (round-trip tests raise it, D7);
- a localized `\ No newline at end of file`;
- input that only parses through recovery (damaged files).

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
  and `UTF8Span` need macOS 26. Q7 settled this: the floors rise to the 26
  releases, so both are usable.
- **Friction:** `Span` isn't a `Sequence` in 6.2, so no `map`/`filter`,
  and there is no `Array(span)`. Copying out takes an index loop or
  `withUnsafeBufferPointer`, which needs `unsafe` under
  `strictMemorySafety()` (and Swift 6.4 warns that one of those `unsafe`
  markers is unnecessary, so warning-free on both compilers needs care).
- **Back-deployment is moot (Q7).** `platforms:` becomes macOS, iOS,
  tvOS, watchOS, and visionOS 26, where `Span` is in the OS, so the
  back-deployed `Span` never runs and no `macos-14`/`macos-15` CI job is
  needed. Linux is unaffected. The change lands with `Span` in 2.4.
  Consequence for 2.9: swift-steward's floor rises from macOS 14 to 26
  when it moves to library 0.2.0, and the tap formula needs a matching
  macOS requirement.

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
(names open), implemented once with a justified `unsafe`; with the 26
floors, `UTF8Span` and `Array.span` keep them simple.
*Trade-offs:* more awkward to consume than a slice; raises the Apple
platform floors to 26 (Q7); pins the callback style (D1) because spans
can't be values.

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
  `ParsingOptions.maximumLineLength` on `DiffEventParser`. The full-model
  convenience entry point (`Diff(diff:)` and its streaming parser
  initializer) raises the cap to 64 MiB (Q4), since that collector's
  memory grows with content anyway; a finite cap still bounds the carry
  buffer against a newline-free stream. Round-trip tests run with the cap raised.
- **Both flags must stay chunk-invariant.** Today `appendCapped` drops the
  excess bytes silently and the CR check looks at the capped line, so a
  `\r` that happens to sit at the cap of an over-long line would be
  misreported. The splitter therefore tracks, across chunks, whether
  bytes were dropped and what the real last byte before `\n` was; the
  1-byte-chunk tests cover it.

### Full-model storage (D8)

Retaining every line of the kernel diff ([M3](#m3-full-model-memory)):

| Layout | Time | Heap allocations | Peak RSS (≈ 80 MB without retaining anything, of which the input buffer is ≈ 74 MB) |
|---|---|---|---|
| Events only, nothing retained | 62 ms | ≈ 12.4k | 80 MB |
| One `[UInt8]` per line | 149 ms | ≈ 1.45M | 358 MB |
| One byte arena per file, lines as offsets | 101 ms | ≈ 175k | 259 MB |

**Recommendation:** per-file arenas, with lines storing offsets and the
file handing out slices on demand (the sketch above). The prototype's line
record is 40 bytes (1.6M lines = 65 MB); with 32-bit offsets the sketch's
record is about 24 bytes, at the cost of a per-file 4 GiB limit to check
(over it, the file is abandoned as damaged). 2.5 documents the result: the full model takes about 2.5×
the diff's size.

## 4. Special inputs

### Combined diffs (`diff --cc`, `@@@`) (D9)

`git show <merge>` and `git log -p --cc` print dense combined diffs, and
`git show -c` the full form: one `diff --cc path` (or `diff --combined
path`) per file, `index a,b..c`, `mode a,b..c` (`mode 000000,100644..100644`
when a parent lacked the file), `---`/`+++`, hunk headers with N+1 `@` and
N+1 ranges for N parents, and N marker columns per line. The
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

**Recommendation (a) for 0.2:** recognize both spellings, and parse the
header into `FileHeader(format: .combined(parents: N))` with the result
side only (new path, mode, and object ID; the per-parent values stay in
the raw header bytes). Cap N at 64 (git's own octopus merges stay far
below it); a larger N abandons the file as damaged. Then
consume `@@@` hunks by counting their declared ranges, and emit no line
events. The counting rule, checked against the example: a line with no
`-` column is in the result and uses the new side's budget, plus parent
*i*'s budget wherever column *i* is a space; a line with a `-` column is
not in the result and uses parent *i*'s budget only where column *i* is
`-`. `ChangedLines` stays
empty for merges, deliberately: the skip is documented at the declarations
(`ChangedLines`, `DiffEventParser`, `FileHeader.Format.combined`) and in
the user docs (2.8), pointing callers to
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

**Recommendation:** mark `isBinary` (the `GIT binary patch` line ends the
header block, so it is part of the raw header), and pass every following
line to `binaryPatchLine` so the full model can keep the block verbatim
for round-tripping. The `literal`/`delta` sizes arrive after `beginFile`,
so they can't live on `FileHeader`; the summary collector parses them
(overflow-checked) from those events if it reports binary sizes. **Don't decode**: inflating zlib without dependencies
means hand-writing a decompressor that has to survive hostile input, for
a feature no planned consumer needs. Today's behavior (no entry, the next
file parses normally) was confirmed on a real `--binary` diff.

### Plain `diff -u` (D11)

GNU/BSD `diff -u` and `diff -ruN` output works today
([M4](#m4-special-inputs-against-todays-parser)): the tab-separated
timestamps are stripped, and `diff -ruN old new` yields `new/f.txt` and
`new/added.txt`. Differences from git output that the model must absorb:

- No extended headers, so the status comes from `/dev/null` — or, with
  `-N`, from an epoch timestamp standing in for it. `git apply` treats an
  epoch timestamp as `/dev/null` (measured: `git apply --summary -p1` on
  the `diff -ruN` sample prints `create added.txt`, though the timestamp
  is `1970-01-01 01:00:00` local time). Follow git, so the 2.3 oracle
  agrees: recognize the epoch timestamp, in any time zone offset, as
  creation or deletion.
- Paths carry the compared directories (`old/`, `new/`) rather than git's
  `a/` `b/`. Keep today's prefix heuristic for every format, so
  `ChangedLines` results don't change — Mercurial's plain output, for
  one, uses `a/` and `b/` — and offer
  `DiffPath.droppingLeadingComponents(_:)` for `patch -p1` style
  stripping. `format: .unified` tells callers which case they have.
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
  checked digit scanner with a cap; a similarity or dissimilarity over
  100 is ignored, as `git apply` ignores it, rather than clamped.
- The header buffer is bounded (a line count and the line cap), so a
  stream of junk header lines can't grow memory. A header block over the
  bound abandons the file as damaged rather than delivering a partial
  raw header.
- `diff --git` splitting, quoted-path unquoting, and `rename from/to`
  parsing degrade to "unknown path" rather than trapping.
- Damage is reported, never logged (Q6): a `damage`
  event, a no-op by default, carries a `DamageReport` with the file (its
  header so far, if any), the input line number, the reason, and a
  severity — `.info` for a local recovery (a header line ignored, a hunk
  cut short), `.error` for an abandoned file. The library stays
  dependency-free; tools such as `steward` log the reports. 2.7 asserts
  "damage stays inside one file" on these events.

## Answered questions

The maintainer answered all seven on 2026-10-25. Each names the decision
it affects; the sections above already reflect the answers.

1. **D1, naming: accepted as proposed.** A generic
   `DiffEventParser<Consumer: DiffEventConsumer>` with `mutating`
   callbacks; `DiffParser` stays as the `ChangedLines` facade until 5.1;
   the models are `Diff`, `DiffFile`, `DiffLine`, and `DiffSummary`.
2. **D5: `Span<UInt8>`, as proposed.** Line content reaches consumers as
   a bare `Span<UInt8>` callback parameter, and the library ships the
   copy-out conveniences so consumers never write `unsafe`. With Q7's
   floors, the back-deployment check on older macOS is no longer needed.
3. **D6: bytes, as proposed** ("since we also support Linux"). The full
   model's paths are `DiffPath`: exact unquoted bytes, with `==` and
   hashing on bytes and a lossy `string`/`description`. `ChangedLines`
   keeps `String` keys and documents that they compare by Unicode
   canonical equivalence, so NFC and NFD spellings of one name, which git
   treats as two paths, share a key.
4. **D7: 64 MiB.** The full-model entry point raises the line cap to
   64 MiB, not unlimited. The 1 MiB default, the `isTruncated` flag, and
   `ParsingOptions.maximumLineLength` stay as proposed.
5. **D9: skip, and document it.** Combined diffs are recognized and
   skipped safely in 0.2, with no line events, as proposed. The skip is
   documented at the declarations and in the user docs (2.8).
6. **Damage reporting: yes, report it** ("log info/errors on damaged
   files"), as an event; the maintainer confirmed this reading the same
   day. The library emits a `damage` event (no-op by default) carrying
   the file, the input line, the reason, and a severity: `.info` for a
   local recovery, `.error` for an abandoned file. Tools such as
   `steward` log it. The library never logs by itself and stays
   dependency-free, so no swift-log.
7. **Platforms: the modern `Span` API, even with higher floors.**
   `platforms:` becomes macOS, iOS, tvOS, watchOS, and visionOS 26, so
   `Array.span` and `UTF8Span` are usable; Linux is unaffected. It lands
   with `Span` in 2.4. Consequence for 2.9: when swift-steward moves to
   library 0.2.0, its floor rises from macOS 14 to 26, and the tap formula
   needs a matching macOS requirement.

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
