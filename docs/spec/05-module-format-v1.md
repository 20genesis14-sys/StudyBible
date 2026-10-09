# 05. Module format v1

**English** | [Русский](05-module-format-v1.ru.md) | [English full spec](en/05-module-format-v1.md)

Status: implemented in `crates/studybible-store` (MVP 2).
**Pre-freeze** mode (decision of 2026-10-12): the schema and semantics
are considered final, but the formal freeze is postponed until feedback
from real users; until the freeze act, edits of existing fields are
allowed with module rebuilds.
Decisions — ADR 0003 (untrusted SQLite, FTS in cache), ADR 0007 (reading
stream). The strictness policy and semantics were fixed on 2026-10-12 —
see the "Semantics" section below.
Format v2 is a separate format, not an evolution of v1 (ADR 0018):
freezing v1 does not constrain the design of v2.

## File

SQLite database, UTF-8. Signature: `PRAGMA application_id = 0x53424D31`
(`SBM1`). `meta` must contain `format_version = "1"`.

## Tables

```sql
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE books(book_id INTEGER PRIMARY KEY, code TEXT UNIQUE NOT NULL,
                   ord INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '');
CREATE TABLE book_headers(book_id INTEGER NOT NULL, marker TEXT NOT NULL, text TEXT NOT NULL,
                          PRIMARY KEY(book_id, marker));
CREATE TABLE blocks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, seq INTEGER NOT NULL,
                    marker TEXT NOT NULL DEFAULT '', PRIMARY KEY(book_id, chapter, seq));
CREATE TABLE spans(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, block INTEGER NOT NULL,
                   seq INTEGER NOT NULL, kind TEXT NOT NULL, num INTEGER,
                   verse INTEGER, start INTEGER, len INTEGER,
                   style TEXT NOT NULL DEFAULT '', attrs TEXT NOT NULL DEFAULT '',
                   caller TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, block, seq));
CREATE TABLE verses(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    text TEXT NOT NULL, PRIMARY KEY(book_id, chapter, verse));
```

Compact schema (ADR 0016 item 15, before the v1 freeze): books are
addressed by a numeric `book_id`, not a text code, and the text is
stored once.

- `books` — `book_id` (equal to `ord`), USFM/OSIS code (`code` UNIQUE),
  order `ord`, title. All other tables reference `book_id`.
- `book_headers` — book headers from USFM (`h`, `toc1`, `mt1`…), except
  `id`.
- `blocks` — the reading stream: the block's USFM marker (`p`, `q1`,
  `s1`, `d`…), empty = continuation.
- `verses` — the canonical **raw** verse text (no footnotes or headings,
  with spaces between spans, as in the stream; a psalm superscription is
  verse 0). This is the only copy of the verse text: `spans.t` is
  sliced from it, and the "flat" text outside is
  `collapse_spaces(verses.text)`. Canonical text equals display text:
  the `/` morpheme separator in `w` spans is removed at write time (the
  renderer used to cut it anyway); spans containing '<' (leftover
  source tags) are untouched.
- `spans` — inline spans of a block. `kind`:
  - `t` — verse text: `verse`+`start`+`len` is a byte slice into
    `verses.text`; `text` is empty. Heading blocks (`verse` NULL) store
    text in `text`.
  - `f`/`x` — footnote/cross-reference: `verse` — the anchor verse,
    `start` — position in the verse text (NULL in old data); the body is
    in `text`.
  - `v` — verse marker (`num`): written only for a verse with no text
    spans (empty verse) and inside heading blocks — markers were stored
    there before. For all other verses the reader synthesizes the
    boundary from the `verse` change across spans.

## `meta` keys

`format_version`, `id`, `title`, `language` (BCP 47), `direction`
(`ltr`/`rtl`), `versification` (`rsc`, `org`…), `name_profile` (`syn`,
`en`), `book_order` (`list`, `syn`), `version`, `license`,
`attribution`, `source`, `content_hash` (SHA-256 of the reading stream —
part of the search cache key), `required` (comma-separated list of
mandatory capabilities). Rights flags — the optional `rights` key (see
extensions below; question № 15 closed). Other keys are kept in `extra`
and do not break reading.

## Safe opening (`Module::open`)

- `SQLITE_OPEN_READ_ONLY` + `PRAGMA query_only=ON` — writing forbidden.
- `PRAGMA trusted_schema=OFF` and `SQLITE_DBCONFIG_DEFENSIVE=ON` —
  protection from a malicious schema; `DQS` off.
- Checks: `application_id`, presence of all tables, expected columns
  (`SELECT … LIMIT 0` preparation), `format_version`, non-empty `id`.
  Any mandatory capability in `required` — refusal
  (`UnsupportedFeature`), since none are supported yet.

## Writing (`ModuleWriter`)

`create` → `add_book` → `add_chapter` (writes `blocks`, `spans`,
`verses`, accumulates the hash) → `finish` (writes `content_hash`,
`COMMIT`, `PRAGMA optimize`). All in one transaction.

## Optional extensions (ADR 0016, before the 1.0 freeze)

None of this is required and none goes into `required`.

- `meta.kind`: `bible` | `interlinear` | `commentary` | `dictionary` |
  `layer` | `critical`.
- `meta.features`: `strongs,morph,tokens,alignment,variants,entries,fts,marks`
  (comma-separated).
- `entries(ord INTEGER PRIMARY KEY, headword TEXT NOT NULL,
  norm TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '')` —
  dictionary entries for `kind=dictionary`: `ord` — order in the
  dictionary, `norm` — lowercase headword form for search (indexes on
  `headword` and `norm`). A dictionary module may have no books or
  chapters — `books` is empty. Author input — TSV `headword  text`
  (`format="entries"` in modules.json; `norm` may be given as a third
  column).
- `tokens(book_id, chapter, verse, seq, surface, lemma, strong, morph, gloss)` —
  original words. Source: OSIS `<w lemma morph>`, USFM
  `\w …|strong lemma x-morph\w*`, MyBible/BibleQuote Strong's tags.
  Filled by the converter.
- `alignment(book_id, chapter, verse, token_seq, block, span)` —
  a link between a token and a stream span (`block` = `blocks.seq`,
  `span` = `spans.seq`). Author input — TSV `reference  original  gloss`.
  The old interlinear form (`spans.attrs` = `gr="…"`) is still read.
- `variants(id, book_id, chapter, verse, token_from, token_to)`,
  `readings(variant_id, seq, text, is_base)`, `witnesses(reading_id, siglum)` —
  the critical apparatus. Input — TSV/JSON.
- `.sbz` — a `.sb` compressed by an external codec, for transfer only;
  import unpacks it. Header: `magic "SBZ1"` + `codec_id` (1 byte) +
  payload. Codecs: `0` = zstd (required), `1` = brotli, `2` = xz
  (reserved); others — for the future, an unknown codec = a clear error.
- `meta.rights` — comma-separated rights flags: `no-distribute`,
  `no-net`, `no-ai`, `no-plugins`. No key = everything allowed; an
  honest agreement, not DRM (question № 15).
- `fts` — FTS5 virtual table `fts(book UNINDEXED, chapter UNINDEXED,
  verse UNINDEXED, norm)` (`tokenize='unicode61'`, `norm` = `for_search`
  of the verse text) — a ready search index inside the module. Built by
  the converter at `"fts": true` in modules.json; a reader without it
  builds the `.idx` cache as before (question № 23).
- `marks(book_id, chapter, verse, seq, offset_ms, dur_ms, text)` — time
  marks: offset from the start of the chapter's audio track (ms),
  `dur_ms` — duration (NULL = until the next mark), `text` — the
  word/phrase for highlighting. For audio Bibles and per-word TTS
  highlighting. Input — TSV (`"marks"` in modules.json):
  `verse<TAB>offset_ms[<TAB>dur_ms][<TAB>word]`, `seq` — row order in
  the verse.
- The place of a footnote and a reference within a verse: an `f`/`x`
  span already stands at its position in the stream (a verse part) —
  for footnotes and cross-references alike. Accepted (ADR 0015, 0016):
  anchor text from USFM `\fq`/`\xq`, OSIS `<catchWord>`, and the part
  letter from `\fr`/`\xo` (`1:1a`). Stored in the footnote's
  `spans.attrs`: `part="a"` (part letter), `q="…"` (quoted anchor
  text). In the chapter JSON — field `a` on `f`/`x` spans.

Exact columns and indexes are fixed at implementation, before the 1.0
freeze. Tools: `studybible module check`, `studybible module pack`, TSV
templates.

### Foreign-format mapping

| Format | Text and verses | Strong's/lemma/morph. | Footnotes | References | Apparatus |
|---|---|---|---|---|---|
| OSIS | `<div type="chapter">`, `<verse>` | `<w lemma strong morph>` → `tokens` | `<note>` → `f`, `<catchWord>` → anchor | `<reference>` in `<note type="crossReference">` → `x` | `<rdg>`/`<note type="critical">` → `variants` |
| USFM | `\c`, `\v`, blocks `\p \q \s \d` | `\w …\|strong="…" lemma="…" x-morph="…"\w*` → `tokens` | `\f … \f*`, `\fq` → anchor | `\x … \x*`, `\xo`, `\xq` → `x` + anchor | separate author TSV |
| Zefania | `<BIBLEBOOK><CHAPTER><VERS>` | `<gr str="…">`/`<gr morph="…">` → `tokens` | `<NOTE>` → `f` | reference attributes → `x` | none |
| MyBible | `verses` + `<S>####</S>` tags | `<S>` → `tokens.strong` | `<f>` → `f` | `<x>`/TSK → `x` | none |
| BibleQuote | chapter/verse tags in htm | `<S>` tags → `tokens.strong` | htm footnotes → `f` | htm references → `x` | none |

Rule: what the source does not provide is not invented; the table is
simply not written.

## Format evolution

Existing fields must not be changed or removed. New — only optional
tables and optional `meta` keys. A capability without which reading is
impossible goes into `required` — old readers refuse with a clear
error.

Pre-freeze exception: the compact schema (above) is the last change of
existing fields before 1.0, accepted deliberately (ADR 0016 item 15):
the format is not published yet, all released `.sb` are local and are
rebuilt by the converter. The reader does not open old `.sb` — refusal
at the column check with a clear error; migration = rebuilding from the
source.

## Semantics

The schema describes how the bytes are laid out; this section — what
they mean. Semantics freezes together with the schema: the meaning of
existing fields must not change even if the column type stays the same.

### Reader strictness policy (decision of 2026-10-12)

- **Structural errors — `BadFormat` refusal**: a required table or
  column missing, `application_id`, `format_version`, a broken
  `(start,len)` slice outside the verse text, a value outside the
  field type's range.
- **Semantic anomalies — soft**: the module is read, the anomaly is
  ignored or shown without the layer. These include: a `v` marker on a
  verse with text spans; a `features` declared without the
  table/data; an unknown `kind` value; `f`/`x` without `start`
  (whole-verse anchor); extra `meta` keys and tables.
- `module check` shows anomalies as **warnings**, not errors.

### Rules (tests reference the numbers)

- **C-1.** `spans.t`: `start`/`len` are **byte** UTF-8 offsets into the
  verse's `verses.text`. The slice must lie within the text and not cut
  a character in the middle; a violation is a structural error.
- **C-2.** `verses.text` — the canonical verse text, equal to the
  displayed one: the `/` morpheme separator in `w` spans is removed at
  write time; the "flat" text = `collapse_spaces(verses.text)`. The
  reader and search work with the already-cleaned text.
- **C-3.** `verse = 0` — a superscription/preface (not a verse): shown
  separately, not part of verse navigation. `verse = NULL` — a span
  outside verse context (a heading block), text in `spans.text`.
- **C-4.** A `v` marker is written only for a verse with no text spans
  and in heading blocks; only `v` has a defined `num` field (verse
  number), for other `kind` it is `NULL`. The reader **must**
  synthesize the verse boundary from the `verse` change across spans; a
  superfluous `v` — an anomaly (soft). In `bible`/`interlinear`, verse
  numbers in a chapter **do not decrease** (a repeat/jump backward is an
  anomaly); in `commentary`/`critical` repeats are legal (a verse
  quote).
- **C-5.** `f`/`x`: `verse` — the anchor verse, `start` — a byte
  position in its text; `start = NULL` — whole-verse anchor.
  `attrs`: `part` — the verse-part letter (`1:1a` → `part="a"`),
  `q` — the quoted anchor text (`\fq`/`\xq`, `<catchWord>`).
- **C-6.** `blocks.marker` determines the layout: empty — continuation
  of the previous block; `q1`/`q2`… — poetry; `s1`/`s2`… — a section
  heading; `d` — a superscription; `p`, `m`, `pi`… — paragraphs.
  The vocabularies of `blocks.marker`, `spans.style` and `spans.attrs`
  keys are **open** (decision of 2026-10-12): the standard set is
  documented, an unknown marker reads as a paragraph, an unknown style
  as plain text, an unknown `attrs` key is ignored.
- **C-7.** Ordinal fields have their own scope: `blocks.seq` — within a
  chapter, `spans.seq` — within a block, `tokens.seq` — within a
  verse, `marks.seq` — within a verse, `entries.ord` — within a
  dictionary.
- **C-8.** `meta.kind` — a composition contract: `bible` — text with
  verses; `interlinear` — the same + `alignment`/`tokens`;
  `commentary` — blocks bound to verses, no verse text; `dictionary`
  and `layer` — `books` may be empty (content in `entries`/apparatus);
  `critical` — carries `variants`. An unknown `kind` reads as `bible`
  (soft).
- **C-9.** `meta.features` — an **open** list. Known values
  (`strongs`, `morph`, `tokens`, `alignment`, `variants`, `entries`,
  `fts`, `marks`) enable UI layers. `x-`-prefixed values are
  experimental and ignored; other unknowns — likewise. A flag without
  data — the layer is not shown (soft).
- **C-10.** `meta.required` — any value = `UnsupportedFeature`, the
  reader must refuse. No supported values in v1.
- **C-11.** `meta.rights` — a behavioral commitment of the app:
  `no-distribute` — do not export/redistribute; `no-net` — do not serve
  over the network; `no-ai` — do not pass to AI features; `no-plugins`
  — do not give to plugins (technically: API v1 host functions refuse).
- **C-12.** `meta.content_hash` — SHA-256 (hex) of the canonical
  reading-stream serialization. Algorithm (exact, decision of
  2026-10-12): for each chapter block in order write
  `"{book} {chapter} {index} {marker}\x00"`, then each span:
  `v` → `"v{num}\x00"`, `t` → `"t{style}\x01{attrs}\x01{text}\x00"`,
  `f`/`x` → `"n{kind}{caller}\x01{attrs}\x01{text}\x00"`. Books and
  chapters go in `books.ord` order, chapters ascending. The hash is
  part of the search-cache key; the reader must store it as a string,
  recomputation is not required. A tool editing a ready `.sb` (e.g.
  `inject_xrefs`) **must** recompute the hash from the readable stream
  (`Module::compute_content_hash`, the `module rehash` command).
- **C-13.** `for_search` (search normalization, `norm_version="2"`):
  lowercase, `ё`→`е`, pre-reform `ѣ`→`е`, `і`→`и`, `ѳ`→`ф`,
  `ѵ`→`и`; removal of soft hyphens U+00AD and combining marks by a
  fixed range list (U+0300–036F, 0483–0489, 0591–05BD, 05BF,
  05C1–05C2, 05C4–05C5, 05C7, 0610–061A, 064B–065F, 0670,
  1AB0–1AFF, 1DC0–1DFF, 20D0–20FF, FE20–FE2F); Hebrew final
  letters `ךםןףץ` → regular; maqqef U+05BE → space; `ς`/`Ϲ`→`σ`;
  `й` is preserved (hidden behind a private-use char until NFD and
  returned). The algorithm is part of the format: `entries.norm` and
  `fts.norm` are built by the same rules.
- **C-14.** `meta.versification` and `meta.name_profile` — profile
  names from the `data/versification/` and `data/profiles/` registries.
  The reader must understand built-in profiles; an unknown name — soft
  (the module's default profile or `org`).
- **C-15.** `meta.direction` (`ltr`/`rtl`) — text layout direction;
  `meta.language` — the language for TTS and search normalization.
- **C-16.** `marks.offset_ms` — offset from the start of the chapter's
  audio track; `dur_ms = NULL` — until the next mark; `text` — the
  check word.
- **C-17.** `.sbz`: only codec `0` (zstd) is required; the reader's
  unpack limit is ~1 GiB (a bigger module — a rightful refusal).
- **C-18.** Unknown tables, columns, `meta` keys and `features` are
  ignored — this is the format's evolution mechanism.
- **C-19.** `chapter = 0` — a book introduction/preface: shown before
  chapter 1, is not a verse chapter (BibleQuote commentaries already
  write it this way).
- **C-20.** Optional tables (`entries`, `tokens`, `marks` etc.) are
  legal with any `kind`: `kind` describes the main contract but does
  not forbid extensions. A Bible with a built-in lexicon is
  `kind=bible` + `features=entries`.
