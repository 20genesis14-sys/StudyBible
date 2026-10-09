# 05. Module format v1

Status: implemented in `crates/studybible-store` (MVP 2).
**Pre-freeze** (decision 2026-10-12): schema and semantics are
considered final, but the formal freeze is postponed until real-user
feedback; until the freeze, changes to existing fields are still
allowed with modules rebuilt.
This is the normative English edition of
`docs/spec/05-module-format-v1.md`; the Russian text is authoritative.
Decisions — ADR 0003 (untrusted SQLite, FTS in cache), ADR 0007
(reading stream). Strictness policy and semantics fixed 2026-10-12 —
see "Semantics" below. Format v2 is a separate format, not an
evolution of v1 (ADR 0018): freezing v1 does not constrain v2 design.

## File

SQLite database, UTF-8. Signature: `PRAGMA application_id = 0x53424D31`
(`SBM1`). `meta` MUST contain `format_version = "1"`.

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

Compact schema (ADR 0016 §15, the last change before the v1 freeze):
books are addressed by numeric `book_id`, not by textual code, and the
text is stored once.

- `books` — `book_id` (equal to `ord`), USFM/OSIS code (`code` UNIQUE),
  order `ord`, title. All other tables reference `book_id`.
- `book_headers` — book headers from USFM (`h`, `toc1`, `mt1`…),
  except `id`.
- `blocks` — reading stream: USFM block marker (`p`, `q1`, `s1`, `d`…);
  empty means continuation of the previous block.
- `verses` — canonical **raw** verse text (no notes or headings, spans
  separated by spaces as in the stream; a psalm superscription is
  verse 0). This is the single copy of the verse text: `spans` rows of
  kind `t` are sliced from it, and the "flat" text outside is
  `collapse_spaces(verses.text)`. Canonical text equals displayed
  text: the morpheme separator `/` inside `w` spans is removed at
  write time; spans containing `<` (source tag remnants) are left
  alone.
- `spans` — inline runs of a block. `kind`:
  - `t` — verse text: `verse`+`start`+`len` is a byte slice of
    `verses.text`; `text` is empty. Heading blocks (`verse` NULL) store
    their text in `text`.
  - `f`/`x` — footnote / cross-reference: `verse` is the anchor verse,
    `start` the byte position in its text (NULL in older data means
    whole-verse anchoring); the body is in `text`.
  - `v` — verse marker (`num`): written only for a verse without text
    spans (empty verse) and inside heading blocks. For all other
    verses the reader synthesizes the boundary from changes of the
    `verse` field of spans.

## `meta` keys

`format_version`, `id`, `title`, `language` (BCP 47), `direction`
(`ltr`/`rtl`), `versification` (`rsc`, `org`…), `name_profile` (`syn`,
`en`), `book_order` (`list`, `syn`), `version`, `license`,
`attribution`, `source`, `content_hash` (SHA-256 of the reading stream
— part of the search-cache key), `required` (comma-separated list of
mandatory capabilities). Rights flags — optional key `rights` (see
extensions below). Other keys are preserved in `extra` and do not
break reading.

## Safe opening (`Module::open`)

- `SQLITE_OPEN_READ_ONLY` + `PRAGMA query_only=ON` — writes forbidden.
- `PRAGMA trusted_schema=OFF` and `SQLITE_DBCONFIG_DEFENSIVE=ON` —
  protection against malicious schemas; `DQS` disabled.
- Checks: `application_id`, all mandatory tables, expected columns
  (`SELECT … LIMIT 0` prepared), `format_version`, non-empty `id`.
  Any value in `required` — refusal (`UnsupportedFeature`), since none
  are supported yet.

## Writing (`ModuleWriter`)

`create` → `add_book` → `add_chapter` (writes `blocks`, `spans`,
`verses`, accumulates the hash) → `finish` (writes `content_hash`,
`COMMIT`, `PRAGMA optimize`). Everything in one transaction.

## Optional extensions (ADR 0016, pre-1.0 freeze)

None of this is mandatory and none goes into `required`.

- `meta.kind`: `bible` | `interlinear` | `commentary` | `dictionary` |
  `layer` | `critical`.
- `meta.features`: `strongs,morph,tokens,alignment,variants,entries,
  fts,marks` (comma-separated, open list — see S-9).
- `entries(ord INTEGER PRIMARY KEY, headword TEXT NOT NULL,
  norm TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '')` —
  dictionary articles for `kind=dictionary`: `ord` — order in the
  dictionary, `norm` — lowercase form of the headword for searching
  (indexes on `headword` and `norm`). A dictionary module may have no
  books or chapters — `books` is empty. Author input — TSV
  `headword<TAB>text` (`format="entries"` in modules.json; `norm` may
  be given as a third column).
- `tokens(book_id, chapter, verse, seq, surface, lemma, strong, morph,
  gloss)` — original-language words. Sources: OSIS `<w lemma morph>`,
  USFM `\w …|strong lemma x-morph\w*`, Strong tags of
  MyBible/BibleQuote. Filled by the converter.
- `alignment(book_id, chapter, verse, token_seq, block, span)` —
  token → its reading-stream span (`block` = `blocks.seq`, `span` =
  `spans.seq`). Author input — TSV `reference  original  gloss`.
  The old interlinear form (`spans.attrs` = `gr="…"`) is still read
  unchanged.
- `variants(id, book_id, chapter, verse, token_from, token_to)`,
  `readings(variant_id, seq, text, is_base)`, `witnesses(reading_id,
  siglum)` — critical apparatus. Input — TSV/JSON.
- `.sbz` — `.sb` compressed by an outer codec, transport only; import
  decompresses. Header: `magic "SBZ1"` + `codec_id` (1 byte) +
  payload. Codecs: `0` = zstd (mandatory), `1` = brotli, `2` = xz
  (reserved); others are for the future, unknown codec = a clear
  error.
- `meta.rights` — comma-separated rights flags: `no-distribute`,
  `no-net`, `no-ai`, `no-plugins`. Missing key = all allowed; an
  honest agreement, not DRM.
- `fts` — FTS5 virtual table `fts(book UNINDEXED, chapter UNINDEXED,
  verse UNINDEXED, norm)` (`tokenize='unicode61'`, `norm` = `for_search`
  of the verse text) — a ready search index inside the module. Built
  by the converter when `"fts": true` in modules.json; a reader
  without it builds the `.idx` cache as before.
- `marks(book_id, chapter, verse, seq, offset_ms, dur_ms, text)` —
  time marks: offset from the start of the chapter audio track (ms),
  `dur_ms` — duration (NULL = until the next mark), `text` — the
  word/phrase for highlighting. For audio Bibles and word-level TTS
  highlighting. Input — TSV (`"marks"` in modules.json):
  `verse<TAB>offset_ms[<TAB>dur_ms][<TAB>word]`, `seq` — order of the
  line within the verse.
- Note/reference position inside a verse: `f`/`x` spans already stand
  in the stream at their place (the verse part). The anchor text comes
  from USFM `\fq`/`\xq`, OSIS `<catchWord>`, and the part letter from
  `\fr`/`\xo` (`1:1a`). Stored in `spans.attrs` of the note:
  `part="a"` (part letter), `q="…"` (quoted anchor text). In chapter
  JSON — field `a` of `f`/`x` spans.

Exact columns and indexes are fixed at implementation time, before
the 1.0 freeze. Tools: `studybible module check`,
`studybible module pack`, TSV templates.

### Foreign-format mapping

| Format | Text and verses | Strong/lemma/morph. | Notes | References | Apparatus |
|---|---|---|---|---|---|
| OSIS | `<div type="chapter">`, `<verse>` | `<w lemma strong morph>` → `tokens` | `<note>` → `f`, `<catchWord>` → anchor | `<reference>` in `<note type="crossReference">` → `x` | `<rdg>`/`<note type="critical">` → `variants` |
| USFM | `\c`, `\v`, blocks `\p \q \s \d` | `\w …\|strong="…" lemma="…" x-morph="…"\w*` → `tokens` | `\f … \f*`, `\fq` → anchor | `\x … \x*`, `\xo`, `\xq` → `x` + anchor | author TSV |
| Zefania | `<BIBLEBOOK><CHAPTER><VERS>` | `<gr str="…">`/`<gr morph="…">` → `tokens` | `<NOTE>` → `f` | reference attributes → `x` | none |
| MyBible | `verses` + `<S>####</S>` tags | `<S>` → `tokens.strong` | `<f>` → `f` | `<x>`/TSK → `x` | none |
| BibleQuote | chapter/verse tags in htm | `<S>` tags → `tokens.strong` | htm notes → `f` | htm links → `x` | none |

Rule: what the source does not provide is not invented; the table is
simply not written.

## Format evolution

Existing fields MUST NOT be changed or removed. New things are only
optional tables and optional `meta` keys. A capability without which
reading is impossible goes into `required` — old readers refuse with a
clear error.

Pre-freeze exception: the compact schema (above) is the last change of
existing fields before 1.0, accepted deliberately (ADR 0016 §15): the
format is not yet published, all released `.sb` files are local and
rebuilt by the converter. The reader does not open old `.sb` — it
fails at the column check with a clear error; migration = rebuilding
from source.

## Semantics

The schema describes how bytes are laid out; this section — what they
mean. Semantics are frozen together with the schema: the meaning of
existing fields MUST NOT change even if the column type stays the
same.

### Reader strictness policy (decision 2026-10-12)

- **Structural errors — refusal** `BadFormat`: a missing mandatory
  table or column, `application_id`, `format_version`, a slice
  `(start,len)` outside the verse text, a value out of the field
  type's range.
- **Semantic anomalies — soft**: the module is read, the anomaly is
  ignored or shown without its layer. These include: a `v` marker on a
  verse that has text spans; a `features` entry with no table/data;
  an unknown `kind` value; `f`/`x` without `start` (whole-verse
  anchor); extra `meta` keys and tables.
- `module check` reports anomalies as **warnings**, not errors.

### Rules (tests reference them by number)

- **S-1.** `spans.t`: `start`/`len` are **byte** offsets into the
  UTF-8 `verses.text` of the verse. A slice MUST lie within the text
  and MUST NOT cut a character in half; violation is a structural
  error.
- **S-2.** `verses.text` is the canonical verse text, equal to the
  displayed text: the morpheme separator `/` in `w` spans is removed
  at write time; the "flat" text = `collapse_spaces(verses.text)`.
  Reader and search work with already-cleaned text.
- **S-3.** `verse = 0` — superscription/preface (not a verse): shown
  separately, excluded from verse navigation. `verse = NULL` — a span
  outside verse context (heading block); the text is in `spans.text`.
- **S-4.** The `v` marker is written only for a verse without text
  spans and inside heading blocks; only `v` defines the `num` field
  (verse number) — it is `NULL` for other `kind`s. The reader MUST
  synthesize the verse boundary from changes of `verse` in spans; a
  superfluous `v` is an anomaly (soft). In `bible`/`interlinear`,
  verse numbers within a chapter are **non-decreasing** (repetition or
  a backward jump is an anomaly); in `commentary`/`critical`,
  repetitions are legal (quoting a verse).
- **S-5.** `f`/`x`: `verse` — anchor verse, `start` — byte position
  in its text; `start = NULL` — whole-verse anchor. `attrs`: `part` —
  the verse-part letter (`1:1a` → `part="a"`), `q` — the quoted
  anchor text (`\fq`/`\xq`, `<catchWord>`).
- **S-6.** `blocks.marker` drives layout: empty — continuation of the
  previous block; `q1`/`q2`… — poetry; `s1`/`s2`… — section heading;
  `d` — superscription; `p`, `m`, `pi`… — paragraphs. The vocabularies
  of `blocks.marker`, `spans.style` and `spans.attrs` keys are
  **open** (decision 2026-10-12): the standard set is documented, an
  unknown marker is read as a paragraph, an unknown style as plain
  text, an unknown `attrs` key is ignored.
- **S-7.** Sequence fields have their own scope: `blocks.seq` —
  within a chapter, `spans.seq` — within a block, `tokens.seq` —
  within a verse, `marks.seq` — within a verse, `entries.ord` —
  within the dictionary.
- **S-8.** `meta.kind` — composition contract: `bible` — text with
  verses; `interlinear` — same plus `alignment`/`tokens`;
  `commentary` — blocks bound to verses, no verse text;
  `dictionary` and `layer` — `books` may be empty (content in
  `entries`/apparatus); `critical` — carries `variants`. Unknown
  `kind` — read as `bible` (soft).
- **S-9.** `meta.features` — an **open** list. Known values
  (`strongs`, `morph`, `tokens`, `alignment`, `variants`, `entries`,
  `fts`, `marks`) enable UI layers. Values with the `x-` prefix are
  experimental and ignored; other unknown values are too. A flag
  without data — the layer is not shown (soft).
- **S-10.** `meta.required` — any value = `UnsupportedFeature`; the
  reader MUST refuse. There are no supported values in v1.
- **S-11.** `meta.rights` — a behavioural obligation of the
  application: `no-distribute` — do not export/redistribute; `no-net`
  — do not serve over the network; `no-ai` — do not feed to AI
  features; `no-plugins` — do not expose to plugins (technically:
  API v1 host functions refuse).
- **S-12.** `meta.content_hash` — SHA-256 (hex) of the canonical
  serialization of the reading stream. Exact algorithm (decision
  2026-10-12): for each chapter block in order emit
  `"{book} {chapter} {index} {marker}\x00"`, then each span:
  `v` → `"v{num}\x00"`, `t` → `"t{style}\x01{attrs}\x01{text}\x00"`,
  `f`/`x` → `"n{kind}{caller}\x01{attrs}\x01{text}\x00"`. Books and
  chapters go in `books.ord` order, chapters ascending. The hash is
  part of the search-cache key; a reader MUST keep it as an opaque
  string and need not recompute it. A tool that edits a built `.sb`
  (e.g. `inject_xrefs`) MUST recompute the hash over the readable
  stream (`Module::compute_content_hash`, the `module rehash`
  command).
- **S-13.** `for_search` (search normalization, `norm_version="2"`):
  lowercase, `ё`→`е`, pre-reform Cyrillic `ѣ`→`е`, `і`→`и`, `ѳ`→`ф`,
  `ѵ`→`и`; removal of soft hyphens U+00AD and combining marks from a
  fixed range list (U+0300–036F, 0483–0489, 0591–05BD, 05BF,
  05C1–05C2, 05C4–05C5, 05C7, 0610–061A, 064B–065F, 0670,
  1AB0–1AFF, 1DC0–1DFF, 20D0–20FF, FE20–FE2F); Hebrew final letters
  `ךםןףץ` → regular; maqaf U+05BE → space; `ς`/`Ϲ`→`σ`; `й` is
  preserved (hidden behind a private-use character before NFD and
  restored). The algorithm is part of the format: `entries.norm` and
  `fts.norm` are built by the same rules.
- **S-14.** `meta.versification` and `meta.name_profile` — profile
  names from the registries `data/versification/` and
  `data/profiles/`. A reader MUST understand the built-in profiles;
  an unknown name — soft (module default profile or `org`).
- **S-15.** `meta.direction` (`ltr`/`rtl`) — text layout direction;
  `meta.language` — TTS voice and search-normalization language.
- **S-16.** `marks.offset_ms` — offset from the start of the chapter
  audio track; `dur_ms = NULL` — until the next mark; `text` — the
  control word.
- **S-17.** `.sbz`: only codec `0` (zstd) is mandatory; the reader's
  decompression limit is ~1 GiB (a larger module may legitimately be
  refused).
- **S-18.** Unknown tables, columns, `meta` keys and `features` are
  ignored — this is the format's evolution mechanism.
- **S-19.** `chapter = 0` — book introduction/preface: shown before
  chapter 1, is not a verse chapter (BibleQuote commentaries already
  write it this way).
- **S-20.** Optional tables (`entries`, `tokens`, `marks` etc.) are
  legal under any `kind`: `kind` describes the main contract but does
  not forbid extensions. A Bible with a built-in lexicon is
  `kind=bible` + `features=entries`.
