# ADR 0018 — module format v2 (after the 1.0 release, no deadlines)

**English** | [Русский](0018-module-format-v2.ru.md)

Status: long-range roadmap. Not implemented before the 1.0 release.
The document's job is to fix the rationale, the layout and the
boundaries so the decision does not have to be reinvented.

## Context and motivation

The current `.sb` format — a SQLite database + the `.sbz` transfer
container (zstd over the whole file). That is the right choice for 1.0:

- FTS5 out of the box (search, snippets, ranking);
- a mature library on all platforms, including sqlite3.wasm;
- module authors can inspect the file in any SQLite viewer.

Also accepted before release: `module build` emits `.sbz` by default;
the app reads the module through `sqlite3_deserialize` — entirely into
memory, no unpacked copy on disk. And on 2026-10-12 — the compact v1
schema (ADR 0016 item 15): `book_id` instead of a text code, verse text
once in `verses.text` (spans are byte slices), `v` markers only on empty
verses. The measurements and estimates below were taken **before** that
schema and describe the worst case; the real v2 delta is now smaller —
this does not cancel the other motives (RAM on deserialization, web
streaming, structural limit).

The limits of this approach are visible on the horizon:

1. **Fleet scale.** A user may have dozens of modules: translations,
   commentaries, dictionaries, originals with apparatus and
   lemmatization. SQLite storage adds noticeable overhead over the
   payload (after the compact schema — b-tree and string keys, not text
   duplication). On one module that is single MBs; on a fleet — hundreds
   of MB.
2. **RAM on deserialization.** `.sbz`-in-RAM keeps the whole unpacked
   module in memory (30–50 MB, a heavy one — 100+ MB). Several modules
   open at once (comparison, several windows) multiply the cost.
3. **Web.** `sqlite3.wasm` needs the whole file: before the first
   chapter is read, the whole module is downloaded. Plus ~1 MB of the
   wasm itself in the bundle.
4. **Structural limit.** Inside SQLite the size can only shrink to the
   b-tree and string-key floor; beyond that — only external compression
   (variant A) or a block VFS (variant B from the discussion, kept as a
   fallback plan).

## Alternatives considered (recorded 2026-10-11)

- **`.sbz` + deserialization into RAM** — accepted as the interim for
  1.0. Does not scale in RAM and does not solve web streaming.
- **Block VFS** (our own sqlite3_vfs, decompressing pages on the fly) —
  a workable option (precedents: SQLCipher, sqlite-zstd-vfs) but leaves
  the web problem (a custom VFS inside sqlite3.wasm) and the SQLite
  overhead. Kept as a fallback plan.
- **Page codec API** (`sqlite3CodecAttach`) — non-public API, a fork of
  SQLite on all platforms, poor ratio (4 KB page). Rejected.
- **Turso/libSQL** — the file format is SQLite-compatible, adds no
  compression; "turso core" is young. Does not solve the size task.
  Revisit if semantic search/sync is needed.
- **DuckDB** — a columnar analytics DBMS; ~50–100 MB binary, weak FTS.
  Not suitable.
- **KV stores (RocksDB, redb, sled)** — only "key→value"; the whole
  search and structural layer is our code. A special case of a custom
  format on someone else's engine.

## Decision: a custom packed format (v2)

Not "instead of SQLite forever", but a **reading format**. SQLite stays
the build/authoring and debugging format (`module build` → `.sb` →
packing into v2). The v2 reader is `studybible-core` compiled natively
and to wasm: one implementation on all platforms, no Dart port for
module reading.

Approximate parameters (measurements 2026-10-11 on rstplus, 47 MB `.sb`):

- raw verse text 6.0 MB → zstd whole ~1.0 MB (17 %), in 64 KB blocks —
  ~1.4 MB (23 %);
- whole-module v2 estimate: ~5 MB vs 47 MB `.sb` and ~10 MB `.sbz`;
- for a regular translation: ~1.5–2 MB vs ~18 MB `.sb`;
- RAM: mmap + on-demand block unpacking → working set 5–15 MB regardless
  of module size;
- web: one file on the server, the reader pulls blocks over HTTP Range —
  a chapter is kilobytes, the module is streamed, not downloaded.

## Format outline (sketch for future design)

Header: magic + format version + pointer to the table of contents.
TOC — a section table (section id, offset, length, codec).

Sections (optionality via the TOC, like `features` in v1):

- **content** — text by chapters, each chapter compressed as a separate
  zstd block: point reads without unpacking the module. Markup (italic,
  Strong's, wj, verse parts) — offsets and attributes inside the chapter
  block, the text is not duplicated.
- **index** — our own inverted index: a dictionary (front-coding),
  delta-encoded positions (book, chapter, verse, position), compressed
  lists. Search — our code: the same `for_search` normalization, bm25,
  snippets. The index is built by the converter and baked into the
  module (an optional section — the app can build the cache itself).
- **xrefs** — cross-references, numeric fields, binding to a verse part
  (part/q) preserved.
- **entries** — dictionary entries for `kind=dictionary`.
- **marks** — audio time marks.
- **variants/readings/witnesses** — the critical apparatus.
- **meta** — a JSON block: id, title, language, versification, rights,
  required/features — carried over from v1.

The query language — only what the UI really uses: words, a phrase in
quotes, a book filter. The full FTS5 MATCH syntax is not reproduced.

## The cost (honestly)

- Our own search subsystem: indexer, queries, ranking, snippets — the
  largest part.
- Authors lose "open in DB Browser" — compensated by `module check`,
  `export`, a debug `.sb` dump.
- Every edge of the format is our bug; mandatory: `module check`, golden
  tests, fuzzing on broken files (a module comes from anywhere — it is
  untrusted input, currently filtered by SQLite).

## Order of future work

1. Section spec with a test fixture (golden files).
2. Container: reader + writer, `module pack v2`.
3. Chapter/verse reading on v2, parity with the old reader.
4. Inverted index: indexer, queries, snippets; the benchmark — FTS5
   output on the same queries.
5. Feature port: xrefs, entries, marks, apparatus, dictionaries.
6. Web: reading over HTTP Range, removing sqlite3.wasm.
7. Migration: `.sb`→v2 conversion, `module check v2`, format
   coexistence policy.

## Extensibility beyond the Bible

The format and architecture must not be rigidly biblical — eventually
the reader should specialize in other corpora (e.g. the Quran:
surah → ayah; or other hierarchical texts).

What must be kept abstract already now:

- **Content model** — the "book → chapter → verse" tree generalizes to
  "section → subsection → unit". Coordinates and navigation rely on the
  module's catalog (`books`), not a hard-coded canon.
- **Versification and book names** — already profiles (`name_profile`,
  `versification`), not baked into the reader.
- **UI** — panes and layers take structure from the module; biblical
  layers (footnotes, cross-references, Strong's) are optional
  capabilities (`features`), not a required part of the schema.
- **Search** — the index is agnostic to unit semantics.

Format v2 reflects this: coordinates are numeric tree levels, level
names and canon come from `meta`/the module catalog. An honest
limitation: a lot of code is already built around "3 levels"
(book/chapter/verse); deeper hierarchies are a separate decision.

## Related decisions

- ADR 0016 — v1 format extensions (kind, features, rights, .sbz).
- Variant B (block VFS) — fallback plan between v1 and v2.
- Freeze: `.sb` v1 freezes at the 1.0 release; v2 is the next version,
  coexistence via `module check` and the converter, without a "silent"
  swap for the user.

## Addendum 2026-10-08 — the contract for UserData and extensions

The cross-translation-records run (stage A) showed: module identity is
only `meta.id`, the file name plays no role. Requirements for v2:

- `meta.id`, `meta.versification`, `meta.content_hash` — an unchanging
  contract: record anchoring (`vrs`, `module_ver`) and the canonical org
  range stand on them. Changing the `content_hash` algorithm in v2 is
  allowed but must be tagged with an algorithm version — otherwise all
  records at once "see" a module change and start re-anchoring.
- A module resolves by `meta.id` via a catalog scan — files may have any
  name (2026-10-08 decision, DECISIONS).
- The extension system (future ADR): API at the request level ("verse",
  "chapter", "search", "meta"), not the file/SQLite-page level. Then a
  storage-format change is invisible to extensions. A v2 plus for
  extensions: HTTP-Range streaming makes "module as a remote resource"
  possible without a full download.
