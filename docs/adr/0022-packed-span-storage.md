# 0022. Packed blob storage for spans/tokens/alignment inside .sb

**English** | [Русский](0022-packed-span-storage.ru.md)

Status: accepted (2026-10-10).

## Context

A text module is much heavier than its source: `eng-kjv2006` is 13 MB of
USFM but 88 MB as `.sb`. Measurement showed the weight is not text —
`verses.text` totals only ~4 MB — but row overhead: ~649 thousand `t`
spans, ~350 thousand tokens, ~350 thousand alignment rows. Each row
carries ~10 columns of keys plus a B-tree primary key; the "envelope"
costs 40–60 bytes per row, i.e. tens of megabytes of pure overhead.

All three tables share the same access pattern: they are read **whole
per chapter/verse** (chapter render, Strong's card, interlinear), never
by an individual row key. That makes them candidates for vectorized
storage: one row per unit (block or verse) holding a compact binary
array.

This is **not** module format v2 (ADR 0018): the file stays SQLite,
`format_version` stays `"1"`, all other tables stay row-based. It is an
evolution of v1 within the "optional additions" rule — but since the
data physically leaves `spans`, a reader that does not know the packing
would silently lose Strong's/styles. Therefore packing is declared a
**required capability** (`meta.required="pack"`): old readers reject the
module explicitly instead of degrading silently.

## Decision

Three new optional tables hold varint-packed payloads:

- `span_pack(book_id, chapter, block, blob)` — all `t` spans of a block
  in `seq` order. Entry: `seq`, `verse` (NULL = heading/intro text),
  `start`,`len` (NULL for heading text), `style`, `attrs`, `text`
  (non-empty only for unanchored heading text). Strings go through a
  per-blob pool (style/attrs repeat heavily: `"w"`, `strong="…"`).
- `token_pack(book_id, chapter, verse, blob)` — the verse's tokens:
  `seq`, `surface`, `lemma`, `strong`, `morph`, `gloss`.
- `align_pack(book_id, chapter, verse, blob)` — `token_seq → (block,
  span)` triples.

Blob encoding: LEB128 varints, then a string pool (count + length-
prefixed UTF-8 entries), then entries with a per-entry flag byte
marking which optional fields are present. The format is frozen in the
codec (`store::pack`); spec `05` documents it for third parties.

`spans`, `tokens`, `alignment` keep their schema (created empty) so old
column checks and tools keep working; `f`/`x`/`v` spans and all other
tables (`variants`, `readings`, `witnesses`, `entries`, `marks`,
`book_headers`) stay row-based — they are few, carry real text bodies,
or need point access (`entries.norm`).

Reading: `chapter()` merges `spans` rows and `span_pack` entries per
block by `seq`; `tokens()`/`alignment()` unpack per-verse blobs. The
reader branches on the presence of pack tables; unpacked modules keep
working unchanged.

`content_hash` is computed from the logical reading stream, so it is
identical for packed and unpacked builds of the same source.

## Consequences

- `eng-kjv2006.sb`: ~88 → ~50 MB expected; `.sbz` 21.5 → ~14–16 MB.
- A packed module cannot be opened by a pre-pack reader — it reports
  `UnsupportedFeature("pack")`. New readers read both layouts.
- SQL-level transparency of Strong's markup is lost (markup lives in
  blobs); `verses` text stays plain SQL. CLI gets an unpack path via
  the public `store::pack` codec.
- Tools writing `f`/`x` rows (e.g. `inject_xrefs`) are unaffected —
  those spans stay row-based.
- ADR 0018 (v2) is unchanged: the blob codec may become the v2 payload
  serialization later.
