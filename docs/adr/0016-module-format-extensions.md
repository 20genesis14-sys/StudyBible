# 0016. Optional module format extensions (before the 1.0 freeze)

**English** | [Русский](0016-module-format-extensions.ru.md)

Status: accepted (2026-10-05).

## Context

The v1 format (`docs/spec/05-module-format-v1.md`) stores the reading
stream. Original words, interlinear and the critical apparatus currently
live in `spans.attrs` (`strong="…"`, `gr="…"`). In the `int_en.sb`
interlinear the main text is the English gloss and the Greek word is an
attribute: the model is inverted. There is nowhere to store the critical
apparatus and alignment.

User's condition: the format must be practical. Converting foreign
modules (OSIS, USFM, Zefania, MyBible, BibleQuote, SWORD) must not be
hard. A module author must not need to know SQL.

## Decision

1. **All extensions are optional.** A v1 module without them remains
   valid. Extensions do not go into `required`: an old app shows the
   text and skips unknown tables (the "Format evolution" rule).
2. **`meta.kind`** — module type: `bible`, `interlinear`, `commentary`,
   `dictionary`, `layer` (a layer without its own text), `critical`.
   **`meta.features`** — comma-separated capability list: `strongs`,
   `morph`, `tokens`, `alignment`, `variants`. The app builds the
   "Layers" sheet from `features`, not from a code table (`kModuleTags`).
3. **`tokens`** — original words: verse, order, form, lemma, Strong's,
   morphology, gloss. The converter fills the table itself from what is
   already in the sources: OSIS `<w lemma morph>`, USFM
   `\w …|strong lemma x-morph\w*`, MyBible/BibleQuote Strong's tags. No
   extra work from the author.
4. **`alignment`** — a link "original token ↔ translation/gloss word".
   Author input — a simple TSV table: `reference  original  gloss`
   (same as the "gloss / greek / pairs" blocks in
   `build-interlinear.py`). The old `gr="…"` form is still read; the
   converter moves it into `tokens`.
5. **`variants` / `readings` / `witnesses`** — the critical apparatus:
   place (verse + token range), readings, witnesses. Input — TSV/JSON.
   A layer module (`kind=layer`) may carry only the apparatus without
   text.
6. **`.sbz`** — a transfer container: a `.sb` file compressed by an
   external codec. Inside — a regular SQLite database. The app unpacks
   the file on import. Header: `magic "SBZ1"` (4 bytes) + `codec_id`
   (1 byte) + payload. Codecs: `0` = zstd (required for readers),
   `1` = brotli, `2` = xz (reserved); other values — for the future, an
   unknown codec gives a clear error. Compression inside the database —
   only for big dictionaries and only through `required`.
7. **`entries`** — dictionary entries (`kind=dictionary` modules,
   2026-10-06). A flat table: `ord` order, `headword`, normalized `norm`
   for search, entry `text`. A dictionary module may have no books and
   chapters — `books` is empty, all content in `entries`. Author input —
   TSV `headword  text`.
7b. **Author tooling.** `studybible module check` — module check with
   clear messages; `studybible module pack` — `.sb` → `.sbz`; a TSV
   template for interlinear and apparatus; a field-mapping table for
   foreign formats in the spec.
   `.sbz` by default (2026-10-11): `module build` produces a compressed
   `.sbz` (zstd, ~17–22 % of the `.sb` size), the intermediate `.sb` is
   deleted. The `"sbz"` key in defs: `false` → only `.sb`, `"both"` →
   `.sb` + `.sbz` (public modules in data/modules.json — the web needs
   the raw `.sb`, sqlite3.wasm reads it directly). CLI commands
   (`info`/`verse`/`read`/`search`/`say`/`check`) accept `.sbz`
   transparently — unpacked to a temp file for the duration.

8. **Binding footnotes and references to a part of a verse**
   (2026-10-05). The span position of `f`/`x` in the stream is preserved
   — applies both to footnotes and to cross-references `x`. Optional
   fields: anchor text (USFM `\fq`/`\xq`, OSIS `<catchWord>`) and the
   verse-part letter (`\fr`/`\xo`, `1:1a`). No data — the reference
   binds to the whole verse; sources without a position (MyBible, TSK)
   convert that way.

9. **`meta.rights`** — module rights flags (2026-10-06, closes question
   № 15). Optional key, comma-separated prohibitions: `no-distribute`
   (do not redistribute), `no-net` (do not serve over the network —
   web/API), `no-ai` (do not pass the text to AI features),
   `no-plugins` (do not give to plugins). No key = everything allowed.
   This is an honest agreement, not DRM; the app respects the flags in
   the UI ("share file", export, repositories).

11. **`fts` — built-in search index** (2026-10-06; closes question
    № 23).
    An optional FTS5 virtual table inside `.sb`:
    `fts(book UNINDEXED, chapter UNINDEXED, verse UNINDEXED, norm)`
    with the `unicode61` tokenizer; `norm` is
    `for_search(verse text)` — the same normalization as the cache
    index. Built at the author's request: `"fts": true` in modules.json
    (`fts` is written into `features`).
    Reader: the table exists — search the module directly; absent —
    build the `.idx` cache index as before (the mechanism stays). The
    web gets a real FTS5 instead of a LIKE scan over spans.
    Clarification (2026-10-11): `fts` is set only in a module released
    for the web; other builds — without it (the table adds ~30–50 %
    weight and is bound to the normalization version).
    Clarification (2026-10-12): decision changed — `fts` is optional
    for any build and off by default (web modules ship without it: the
    russyn file would grow from 13.2 to 24.1 MB). The web bridge builds
    FTS5 in the in-memory database in the background after opening the
    module (`norm_version` is set on completion; until ready — a LIKE
    scan). The index lives one session; a persistent cache (IndexedDB)
    is an open question.

    Normalization version (2026-10-07, question № 14): the `for_search`
    rules were extended (Hebrew final letters → regular, maqqef U+05BE
    → space, ς→σ), so indexes built by the old rules are incompatible
    with new queries. The `TOKENIZER_VERSION` constant in `search.rs`
    was raised to "2" — it is part of the `.idx` cache key, old caches
    rebuild themselves. For the built-in `fts` in `.sb` the converter
    writes `meta.norm_version = "2"`; a module with `fts` but without
    the key or with a different version has its built-in index ignored
    and the reader falls back to the `.idx` cache (web — to the LIKE
    scan). Modules with an old `fts` do not need rebuilding.

12. **`marks` — time marks** (2026-10-06). Optional table
    `marks(book, chapter, verse, seq, offset_ms, dur_ms, text)`:
    offset from the start of the chapter's audio track in ms,
    `dur_ms` — duration (NULL = until the next mark), `text` — the
    word/phrase for highlighting and checking. Groundwork for audio
    Bible sync and per-word TTS highlighting (Piper/Silero).
    Author input — TSV (`"marks"` in modules.json).

14. **MyBible and BibleQuote sources** (2026-10-07). Two new converter
    inputs (`parse_file`/`parse_dir` → `Vec<usfm::Book>`):
    - `format="mybible"`: a `*.SQLite3` module (tables `info`, `books`,
      `verses`; optional `stories` — section headings → `s1`). The
      MyBible book number (10 = Gen … 730 = Rev; non-canonical — 170
      Tobit, 180 Judith, 270 Wisdom, 280 Sirach, 315 Ep Jer, 320 Baruch,
      462/464/466 Maccabees, 145 Pr Manasseh, 165/468 Ezra etc.) maps to
      the catalog code; an unmapped number is an error, not a skip.
      Verse-text markup: `<S>N</S>` — a Strong's number on the previous
      word (`strong=` on a `w` span, H/G prefix by
      `info.strong_numbers_prefix` or testament), `<f>`/`<n>` — a
      footnote, `<i>` — `\add`, `<J>` — `wj`, `<h>` — a section
      heading, `<pb/>`/`<br/>` — paragraph/line break; other tags are
      stripped. With `kind="commentary"` a `*.commentaries.SQLite3` is
      read (`commentaries` — a verse range, bound to the first verse);
      with `kind="dictionary"` — `*.dictionary.SQLite3`
      (`dictionary(topic, definition)` → `entries`, like a dictionary
      TSV). When building a Bible, companion `*.commentaries.`/
      `*.dictionary.` files in the source directory are skipped.
    - `format="biblequote"`: a directory (or `.zip`) with `bibleqt.ini`
      — keys `BibleName`, `Bible` (Y — Bible, N — commentary),
      `ChapterSign`, `VerseSign`, `StrongNumbers`, `ChapterZero`,
      `BookQty` and per-book `PathName`/`FullName`/`ShortName`/
      `ChapterQty`. File encoding: UTF-8 (including BOM) or
      windows-1251 (`encoding_rs`). A book maps to a code by name via
      the catalog: exact FullName match → exact ShortName → tokens of
      the alias list (order matters: "Первая книга Царств" is 1 Samuel
      in Synodal numbering, not 3 Kings; ordinal numbers normalize to
      digits). Unmapped — an error. With `Bible=N`/
      `kind="commentary"` — a commentary module: "Стихи a-b"/"Стих a"/
      "Verses a-b" sections bind to the first verse of the range (like
      gen_henry.py for comm-henry.sb); repeated markers on one verse
      merge into one entry; with `ChapterZero=Y` the book's preface is
      prepended to the first section of the first chapter.
      Real format deviations (the Henry module, BibleQuote-Modules):
      BibleQuote 7 ini — no `[sections]`, books described by repeating
      groups of top-level keys (a new book starts at `PathName`);
      `ChapterSign=<!--PART-->`; `ShortName` — a space-separated alias
      list.

15. **Compact schema** (2026-10-11, before the v1 freeze). The SQLite
    overhead (~2.5–3× over the payload) is reduced by three measures:
    - `book_id INTEGER` instead of a text book code in all keys:
      `books(book_id PK, code UNIQUE, ord, title)`; the `blocks`,
      `spans`, `verses`, `tokens`, `alignment`, `variants`, `marks`,
      `book_headers` tables store `book_id`. The reader gets code ↔ id
      from `books`.
    - Text stored once: `t` spans hold not the text but a slice
      `(verse, start, len)` — byte offsets into the verse's
      `verses.text`; heading-block text (`verse` NULL) still lives in
      the span's `text`. Footnotes `f`/`x` store the anchor
      `(verse, start)` — a position in the verse text; the body is in
      `text`.
    - `v` markers nearly disappear: a verse boundary is recovered from
      the `verse` of t-spans and the `verses` table; `kind='v'` is
      written only for a verse with no text spans (an empty verse) —
      to keep its position in the stream — and inside heading blocks
      (markers were stored there before; `chapter()` behavior is
      preserved). The reader synthesizes `Span::Verse` before the first
      span of a new nonzero verse — verse 0 (superscription) gets no
      marker, as in the source stream.
    - `x` notes stay in `spans`: moving them to a separate `xrefs`
      table is postponed — our targets are stored as a display string
      ("Gen 7:17; …"), not structural coordinates, so normalizing
      targets compresses nothing. The item stays in ADR 0018 for
      format v2.
    - Canonical text = display text. The `/` morpheme separator inside
      `w` spans (sources like OSHB: "וָ/יָֽפֶת") is removed at write
      time — previously the renderer cut it at display, and it never
      reached `verses.text`; it must not reach the search index or TTS
      either. Spans containing '<' are untouched (leftover source tags,
      where '/' is part of the markup).
    Implemented (2026-10-12). Old `.sb` (text `book`, text duplicated
    in `verses`+`spans.t`, `kind='v'` on every verse) are **not
    supported** by the reader: the format is not frozen yet, all
    released modules are local — rebuilt by the converter or migrated
    by the `migrate_sb11.py` script (data outside the repository) —
    the migration was verified by line-by-line comparison of the
    stream and verse texts. Rejection — at the column check on open
    (`BadFormat`). This is the last edit of existing fields before
    1.0; from now on — only optional additions per the "Format
    evolution" rule.

## Consequences

- A simple module is made as before: USFM/OSIS → converter → `.sb`.
- Interlinear and apparatus — also from plain text tables.
- The extension schema freezes together with the format in 1.0.
