# 0025. Extended Strong's lexicon, original-language base layer, interlinears and tagging layers

**English** | [Русский](0025-extended-strongs-interlinear.ru.md)

Status: accepted (2026-10-13); implementation not started. The full
work plan, task breakdown, data inventory and skill specifications live
in the handoff spec [docs/strongs/HANDOFF.md](../strongs/HANDOFF.md).

## Context

The app ships a classic Strong's dictionary (openscriptures, 1890s
numbering) and shows Strong's numbers only where a module carries them.
Goals of this track:

1. A **universal, updated Strong's lexicon** built on open STEPBible
   data (extended and disambiguated Strong's numbers), first in English,
   then localized (Russian first, later any language).
2. **Interlinears** in any language built from the same lexicon.
3. **Strong's tagging of translations that have none**, published as
   add-on layers that attach to an existing translation without
   redistributing its text (the AndBible-style "number list per verse").
4. Feeding the **Tree of Knowledge** (ADR 0024) with word-level person and
   place mentions.

Findings that shaped the decision (verified 2026-10-12/13):

- TAHOT/TAGNT tag every word (morpheme-split) with a *disambiguated*
  Strong's number (dStrong, e.g. `H5414H`) and a context English gloss;
  the TAHOT sense label (`to give:2_put;_set`) is simply the TBESH
  sub-meaning of that dStrong (G→1, H→2, …). **The dStrong already is
  the word sense** — no mapping to BDB senses is needed (BDB sense
  numbering differs and is not aligned).
- TBESH extended numbers match OpenScriptures augmented Strong's
  9 289 / 9 296; the chain dStrong → eStrong → `AugIndex` →
  `LexicalIndex` → BDB entry resolves for 9 258 / 9 299.
- The TBESH **Meaning** column is based on the Online Bible abridged
  BDB (© Larry Pierce); its header asks for permission before use.
  Permission was requested on 2026-10-13 (pending). Gloss, numbering,
  transliteration, morphology and relations are Tyndale/STEPBible work
  under CC BY 4.0.
- TBESG definitions: Abbott-Smith (public domain) 5 607 and STEPBible
  39 in the NT range G1–G5624; Middle Liddell (Perseus, likely
  CC BY-SA) only 63 there (+13 in G6000–6099). TFLSJ is derived from
  Perseus LSJ (CC BY-SA 4.0).
- Greek has few sense-level dStrongs (292 lettered in the NT range);
  candidates for Greek senses: TAGNT "Sub-meaning" column, MACULA
  Louw–Nida domains.
- TTESV (STEPBible tags for ESV) is **CC BY-NC**; ESV text is
  copyrighted. BSB tables (bereanbible.com) are CC0 with word-level
  links to WLC/Nestle — an independent gold standard. The eBible BSB
  USFM has shifted Strong's tags (unusable as gold).
- Clear-Bible/Alignments (CC BY 4.0) contains manual word alignments,
  incl. the Russian Synodal (RUSSYN, OT+NT, BiblioNexus 2024) and BSB;
  a quick check found 13–14 % of aligned RUSSYN target ids on
  punctuation and a mismatch in Gen 1:2 — quality must be measured
  before use.

## Decision

1. **Module set** (all format v1, optional tables per S-20):

   | Module | kind | Licence |
   |---|---|---|
   | `strongs-step` — universal lexicon | `dictionary` | CC BY 4.0 |
   | `strongs-step-<lang>` — localized overlay | `dictionary` | CC BY 4.0 |
   | `step-orig` — original-language base layer (TAHOT/TAGNT) | `interlinear` | CC BY 4.0 |
   | interlinear per language | `interlinear` / overlay | CC BY 4.0 |
   | `<target>-strongs` — tagging layer of one translation | `layer`, `features=strongs` | CC BY 4.0, or CC BY-NC when TTESV was an input |
   | `lsj` — full LSJ (TFLSJ), optional | `dictionary` | likely CC BY-SA |

2. **Lexicon key = dStrong** (`H5414H`); eStrong and the classic number
   are fallback keys (`lex_base`). Morphemes `H9xxx` are entries too.
   Definitions live in a separate table with a **switchable source**
   (`def_source`, `def_license`): default — OpenScriptures BDB for
   Hebrew, Abbott-Smith + STEPBible for Greek (the 76 ML entries in the
   NT range are replaced); TBESH Meaning is added as a second row only
   if Online Bible grants permission — switching requires no rebuild of
   anything else.
3. **Base layer** `step-orig`: every TAHOT/TAGNT word with address
   (`Gen.1.1#03`), morphemes, dStrong, lemma, morphology, context
   English gloss, editions (NA/TR/Byz…, Ketiv/Qere), person/place ID,
   and later the MACULA word id. `eng` versification.

   Concrete schema (v0.1.0): one `p` block per verse; **one span per
   morpheme** (TAGNT words are single morphemes). Each span has
   `style='w'`; its `text` is the context English gloss of the
   morpheme (punctuation morphemes such as `H9016` ׃ carry the
   character itself). The verse text therefore reads as an English
   context translation in original word order. Span attributes:

   | attr | content |
   |---|---|
   | `gr` | surface form of the morpheme (vocalised) |
   | `strong` | dStrong code (single; braces of the source dropped) |
   | `morph` | morphology code of the morpheme |
   | `lemma` | lexical/dictionary form |
   | `wid` | TAHOT/TAGNT word address `Gen.1.1#03` — identical for all morphemes of a word |
   | `typ` | source letter(s): TAHOT `L|R|X|Q|Q(K)|…`, TAGNT `N|K|O` and combos (`NKO`) |
   | `ed` | edition list (`NA28+NA27+Tyn+SBL+WH+Treg+TR+Byz`) — TAGNT only |
   | `sns` | sense label (`1_beginning`) when tagged |
   | `eid` | person/place entity id (`Abraham@Gen.11.26-1Pe`) when present |
   | `conj` | conjoin phrase reference (`#04»05:G2501`) when present |
   | `mid` | MACULA token id — OT `oBBCCCVVVWWWP` (morpheme part), NT `nBBCCCVVVWWW` — only where an order-verified match exists |

   `mid` is assigned per verse only where the module word count equals
   the source (WLCM/SBLGNT) word count and the ordered forms match;
   otherwise it is left empty and counted in the build report.
   `tokens`/`alignment` are derived automatically (`tokens.surface` =
   `gr`, `tokens.gloss` = span text).
4. **Interlinears**: the primary product is the **dictionary
   interlinear** — the dStrong gloss under every original word plus a
   morphology line (TEHMC/TEGMC). It needs no model for a new language
   beyond translating the glosses and the morphology table. The English
   context interlinear (TAHOT/TAGNT gloss column) replaces the personal
   `int_en.sb`. A context interlinear per language is optional later.
   The reverse interlinear (translation ↔ original) is derived from a
   tagging layer.
5. **Tagging layer** `<target>-strongs`: `links(book, chapter, verse,
   word, ref, strong, conf, flags, source)` in the **target's own
   versification** (word indices refer to its text); bound to the target
   by `target_id`, `target_hash`, `tokenizer`. Applied at read time
   only when all three match. One word tokenizer lives in the core
   (`studybible_core::text::words`, versioned `w1`); tooling obtains
   words only via `studybible tokenize`.
6. **Confidence scale 0–10** (`conf`) on every translated or tagged
   item, with `flags` (reasons), `review` (`auto|judge|human`),
   `source`. Meaning of levels: 10–9 accepted automatically; 8
   accepted with a note; 7–6 shown in the app as **disputed** (with
   the alternative); 5 — manual review, shown as disputed; 3–4 — manual
   review, hidden by default; 0–2 — not published. The score combines
   independent variants, back-translation, an independent judge model
   and rule checks; thresholds are tuned on development books, frozen
   before held-out measurement, and **calibration** (error rate per
   level must be monotonic) is an acceptance criterion.
7. **Tagging pipeline**: deterministic candidates from the verse's base
   layer filtered by the translation's edition → statistical alignment
   (eflomal) → lexical priors → combination; a model is used only for
   unresolved words, strictly choosing among the verse's candidates, in
   three passes per chapter: align → independent review → chapter
   reconcile (the OpenBible ASV interlinear process). Model steps run
   **as an agent per chapter**; every chapter records provenance (model
   and version, rules version, date, scores); runs are resumable.
   Gold data is never put into prompts.
8. **English first, quality gate before any other language.** Gold:
   BSB tables and Clear manual BSB alignment (primary), KJV own tags,
   TTESV on held-out books, OpenBible ASV interlinear for comparison.
   Held-out books (never an input in any form): Ruth, Jonah, Ezra,
   Ps 1–41, Isa 40–55, Mark, Philippians, James, Rev 1–5. Gate: F1 on
   content words on held-out books ≥ inter-gold agreement minus N
   points (N fixed before the run), dStrong accuracy on proper names
   ≥ 95 %, monotonic `conf` calibration. Words whose gold counterpart
   has no source word in the translation's edition are reported as
   **textual-basis differences** and excluded from the main metric —
   100 % agreement is neither expected nor possible.
9. **TTESV policy**: allowed as an input (lexical priors) on development
   books only; layers that used it are marked CC BY-NC. The lexicon and
   the base layer never contain TTESV-derived data. ESV text is used
   only for verification and never distributed.
10. **Russian** (after the gate): overlay lexicon (glosses and
    morphology first; full definitions after the Online Bible answer —
    translate once, from the chosen source), Russian dictionary
    interlinear, Synodal tagging layer — derived from the Clear manual
    RUSSYN alignment if measurement F validates it, otherwise produced
    by the pipeline; gold: Clear RUSSYN (if valid), RST+ (after the
    MyBible importer fix), ru_rob.
11. **Tree of Knowledge feed** (ADR 0024 stage 1): person/place IDs in
    TAHOT/TAGNT + TIPNR give word-level `verse_mentions`,
    `relationships`, `entities`; OpenBible Geocoding gives coordinates;
    MACULA participant referents are an optional extra mention source;
    localized `entity_names` come from tagging layers.
12. **Data pinning**: every external source is pinned in
    `data/sources.json` (commit + SHA-256) and fetched by
    `scripts/fetch-data.ps1` into `STUDYBIBLE_DATA/sources/strongs/`;
    STEPBible attribution and a list of our changes accompany derived
    modules.

## Alternatives rejected

- **KJV as the tagging reference** (AndBible proposal): classic numbers
  only, no sense disambiguation, an English pivot for other languages.
  The original-language base layer is the pivot instead.
- **Mapping STEPBible senses to BDB sense numbers**: the systems differ
  in purpose and granularity; dStrong already encodes the sense.
- **One annotation module for all translations**: a word index is
  meaningful only for one text; universality comes from the lexicon and
  the base layer, the per-translation layer stays thin.
- **Full LSJ inside the core lexicon**: Greek only, ~32 MB of HTML,
  likely CC BY-SA, not translatable — kept as an optional module.

## Consequences

- No format change: new modules use existing kinds and optional tables;
  the reader gains layer application, extended-number lookup and a
  disputed-item display.
- App fixes required (separate commits): MyBible importer keeps only the
  last of several `<S>` tags per word (6.8 % of tagged words in RST+
  lose a number); `normalizeStrong` rejects `H0029G` and unfoldingWord
  `G15100`; BSB module to be rebuilt from `bsb_tables.tsv`.
- The Online Bible answer blocks nothing before Russian definition
  translation (phase 8.1); without it the default definitions are used.
- Cost concentrates in model passes; the dictionary interlinear for a
  new language is nearly mechanical.
- ADR 0024 is amended: `entities.strongs` holds dStrongs.

## Addendum 2026-10-13 — phase 1 results

Measurements A–G ([PROGRESS.md](../strongs/PROGRESS.md)) settle three
open points of this ADR:

- Item 10: the Clear RUSSYN alignment is unusable as published (target
  ids shifted against the word list) — the Synodal layer is produced by
  the pipeline; gold: RST+ (after the importer fix) and ru_rob.
- Greek senses for the interlinear: MACULA Louw–Nida domains (93 % of
  NT words), subject to the MARBLE licence check; TAGNT numbered senses
  cover only 6 %.
- Gate ceiling for content words ≈ 95 % (BSB tables ↔ Clear BSB);
  evaluation normalizes NT Strong's form numbers to lemma numbers and
  scores function words separately.
