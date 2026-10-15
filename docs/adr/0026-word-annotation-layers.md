# 0026. Word-anchored annotation layers (BAB marks and similar)

**English** | [Русский](0026-word-annotation-layers.ru.md)

Status: accepted (2026-10-15); table implemented in `engbsb-bab.sb`.

## Context

Berean Annotated Bible (BAB) carries 52k inline annotations over the
BSB-2025 text: emphasis glosses `(…)`, original-language names `{…}`,
alternate readings `[…]`, literal translations `\…/`, cross-references
and measurements `<…>`, and the plural-`you` marker `⁺`. Each mark
needs: a **word anchor**, a **kind**, a **text payload**, and sometimes
a **target** (dStrong key, verse references).

No existing table fits (see ADR 0025 for why coordinates are words):

- `links` is word → dStrong; its `strong` column is consumed by the
  reader as a lexicon key, and its primary key `(b,c,v,word)` forbids
  two marks on one word (`God{Elohim}⁺` is real);
- `spans` use character offsets — brittle under text drift, which is
  exactly why the Strong's layer uses the `w1` tokenizer;
- `marks` is audio timestamps; `xrefs_pack` is structural xref targets.

## Decision

1. **Generic table** `annotations` inside a layer `.sb` (one layer per
   annotation corpus; first instance: `engbsb-bab`):

```sql
CREATE TABLE annotations(
    book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
    verse INTEGER NOT NULL,
    word INTEGER NOT NULL,          -- w1 word index of the anchor;
                                    -- -1 = verse-level mark
    wlen INTEGER NOT NULL DEFAULT 1,-- words covered (always 1 for BAB)
    kind TEXT NOT NULL,             -- mark kind letter, layer-defined
    text TEXT NOT NULL DEFAULT '',  -- mark payload (gloss, name, …)
    target TEXT NOT NULL DEFAULT '',-- normalized target (dStrong,
                                    -- 'JHN 1:1; HEB 11:3')
    conf INTEGER NOT NULL DEFAULT 0,-- 0-10 binding confidence
    flags TEXT NOT NULL DEFAULT '', -- comma tags, see below
    source TEXT NOT NULL DEFAULT ''
);
```

   No primary key (rowid order kept); index on
   `(book_id, chapter, verse)`. `book_id`/`verse` follow the target
   module; `word` follows its `w1` tokenizer (ADR 0025).

2. **Layer metadata**: `kind='layer'`, `features='annotations'`,
   `target_id`/`target_hash`/`tokenizer='w1'` as in ADR 0025.
   `draft=1` marks a draft-quality corpus (BAB is an "early draft") —
   readers may show a draft badge.

3. **`kind` vocabulary is per-layer**; for `engbsb-bab`:
   `e` emphasis `(…)`, `o` original-language name `{…}`,
   `a` alternate reading `[…]`, `l` literal translation `\…/`,
   `x` cross-reference and `m` measurement `<…>` (the `<…>` source
   notation splits into `x`+`m` rows), `p` plural-you `⁺`.

4. **`flags` vocabulary** (comma-separated):
   `dup` — the mark content is already present verbatim in the target
   text (e.g. BSB's own parentheses swallowed as `e`) — readers must
   not render these; `near` — the anchor word itself did not survive
   the source/target diff, bound to the nearest aligned word to the
   left; `verse` — no aligned word found, mark is verse-level
   (`word=-1`); `noent` — `{…}` name has no resolved dStrong target
   yet (awaits the knowledge-graph entity link).

5. **Builder**: `D:\StudyBible-data\work\bab\build_bab.py` —
   parses `bab.txt`, aligns BAB base words to module words via LCS
   (same routine as the Strong's rebind), anchors each mark to the
   last word ending at/before the mark position, splits `<…>` into
   `x`/`m`, maps unambiguous `{…}` names to dStrong keys.
   Receipt: `work/bab/receipt-bab.json`.

## Consequences

- The contract is corpus-agnostic: any future inline-annotation layer
  (glossary marks, study-Bible notes, translation choices) reuses
  `annotations` with its own `kind` dictionary.
- Renderer/bridge support is a separate task: marks can be injected
  as verse notes (existing `inject_verse_note`), as `strong` attrs
  (`o` with dStrong target), or as a `bab=` attr driving a badge
  widget — UI fidelity decision deferred (BAB is a draft).
- `word=-1` marks degrade gracefully to verse-level display.
