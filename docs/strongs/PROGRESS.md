# Extended Strong's track — progress log

**English** | [Русский](PROGRESS.ru.md)

Live status of the plan in [HANDOFF.md](HANDOFF.md) (decision: ADR 0025).
Update this file at the end of every work session: status table, the
phase section, and the log at the bottom. Numbers here are the
authoritative results; raw reports live in
`STUDYBIBLE_DATA/work/strongs/measure/` (`<X>.json` + `<X>.md`),
produced by `tools/strongs/measure/*.py`.

## Status

| Phase | Status | Date | Artifacts |
|---|---|---|---|
| 0 — documents, data pinned | ✅ done | 2026-10-13 | ADR 0025, ADR 0024 addendum, DECISIONS, OQ 48–53, HANDOFF, `data/sources.json` |
| 1 — measurements A–G | ✅ done | 2026-10-13 | `tools/strongs/measure/`, reports A–G (below) |
| 2 — lexicon `strongs-step` | ⏳ not started | | |
| 3 — base layer `step-orig` | ⏳ not started | | |
| 3b — mega-encyclopedia stage 1 | ⏳ not started | | |
| 4 — English interlinears | ⏳ not started | | |
| 5 — layer format, tokenizer, app, importer fixes | ⏳ not started | | |
| 6 — tagging pipeline | ⏳ not started | | |
| 7 — English evaluation (gate) | ⏳ not started | | |
| 8 — Russian | ⏳ blocked by gate (7); 8.1 definitions wait for OQ 48 | | |

External: Online Bible permission (OQ 48) — requested 2026-10-13, no
answer yet.

## Phase 1 — measurements (done 2026-10-13)

Run: `cd tools/strongs/measure && py -X utf8 <script>.py` (each 1–4 min;
`common.py` holds the loaders). Inputs: `STUDYBIBLE_DATA/sources/strongs/*`,
KJV USFM `sources/eng-kjv2006`, `modules/rstplus.sb`.

### A. Classic number → dStrong (`a_resolvability.py`)

Share of (verse, classic number) pairs of a gold that map to exactly one
dStrong in the same STEPBible verse:

| Gold | pairs | unique | several dStrongs | absent in verse |
|---|---|---|---|---|
| BSB tables | 373 142 | 98.5 % | 0.4 % | 1.2 % |
| KJV | 310 076 | 95.8 % | 0.4 % | 3.8 % |
| ESV/TTESV | 338 533 | 96.3 % | 0.4 % | 3.4 % |

OT unique 97.5–99.2 %, NT 90.6–96.8 %. **Conclusion:** given a classic
number on a word, the dStrong is determined without a model in ~96–98 %
of cases; "several" is rare (H1121 "son", H834, H1004, H1697…).

### B. Inter-gold agreement (`b_gold_agreement.py`) — gate ceiling

Word level, same text (BSB tables ↔ Clear manual BSB):

| Class | words | agree |
|---|---|---|
| OT content | 271 539 | 94.9 % |
| NT content | 82 436 | 95.4 % |
| OT function | 283 671 | 91.1 % |
| NT function | 89 566 | 86.3 % |

Function-word disagreement is mostly convention: BSB tables tag every
word of a phrase ("the heavens" → H8064 on "the"), Clear tags the head.
Verse-set level (share of A's numbers found in B's verse): KJV↔ESV
97.8 / 89.6 %, BSB tables↔ESV 87.9 / 96.8 %, BSB tables↔KJV 80.2 /
96.6 %, BSB tables↔Clear BSB 93.5 / 79.4 %.
**Conclusion:** ceiling for content words ≈ **95 %**; the gate's N is
applied to this number (N still to be frozen, OQ 52). Function words
must be scored with a convention-aware rule (head vs whole phrase) or
reported separately.

### C. Versification (`c_versification.py`)

- TAHOT: 2 094 verses where the Hebrew numbering differs (Psalms 1 104).
- Verse inventory (eng): STEPBible lacks 9 verses that others have
  (Jn 7:53, Rom 16:25–27, 2Co 13:13–14, Php 1:16–17, 3Jn 1:15 —
  different placement); BSB/KJV have no Psalm titles as v.0 (133/120);
  ESV lacks 17 NT verses (Mt 17:21…).
- eng → rsc (via org, `data/versification/*.vrs`): 2 812 verses change
  number; only 10 mappings are not one-to-one (Neh 7:67, several Psalm
  titles, Ps 87:1, 116:10, 147:12, Isa 63:19).
**Conclusion:** existing `Versification::convert` covers Synodal; the 10
non-1:1 cases go to `verse_map` review in phase 6.

### D. Textual basis and numbering conventions (`d_textual_basis.py`)

| Gold | Testament | found in its edition | form number → lemma | only in other edition | absent |
|---|---|---|---|---|---|
| BSB tables | OT | 99.6 % | 0.0 | 0.0 | 0.3 % |
| BSB tables | NT | 96.7 % | 0.4 | 0.3 | 2.6 % |
| KJV | OT | 99.0 % | 0.6 | 0.0 | 0.5 % |
| KJV | NT | 90.8 % | **5.9 %** | 0.0 | 3.3 % |
| ESV/TTESV | OT | 98.1 % | 0.1 | 0.0 | 1.9 % |
| ESV/TTESV | NT | 92.7 % | 3.2 % | 0.8 % | 3.3 % |

**Conclusions:** (1) true edition differences are small (≤ 0.8 %);
(2) KJV and TTESV use Strong's **form numbers** in the NT (G2076 "he
is", G5213 "to you", G2257 "of us") where STEPBible uses lemmas (G1510,
G4771, G1473/G3165) — TBESH/TBESG give 315 such links, more are needed
(G2257, G3450→G3165…); evaluation must normalize form numbers to lemmas;
(3) ESV "absent" H4480 (1 987) and H2088/H2009 are TTESV tagging
choices — expected gold noise.

### E. Greek senses (`e_greek_senses.py`)

- TAGNT "Sub-meaning" is filled for 100 % of words but is mostly a
  context gloss of the form ("him / to him / of him"); real numbered
  senses (`word|1_sense`) — only 6.2 % of words, 48 lemmas.
- Lettered Greek dStrongs: 6.3 % of words.
- MACULA SBLGNT Louw–Nida domain: 93.1 % of words; 1 522 of 4 972
  lemmas have ≥ 2 domains.
**Conclusion (OQ 51):** Greek sense-level interlinear needs MACULA
Louw–Nida (subject to the MARBLE licence check, OQ 49); TAGNT alone
is not enough. Hebrew uses TAHOT/TBESH senses (37 % of words labelled).

### F. Clear manual alignments (`f_clear_alignments.py`)

- Consistent sets (≤ 0.1 % ids on punctuation): eng BSB (WLCM 99.8 %,
  SBLGNT 99.6 % coverage), eng YLT, arb AVD/ONAV, hin, spa RV09
  (partial coverage 54–72 %), asm, ben, por, hau NT.
- **Broken:** rus RUSSYN (13–14 % of ids on punctuation), fra LSG NT
  (7 %), fra LSG OT and hau OT (ids not in the target list), eng BSB
  BGNT (target list mismatch).
- RUSSYN vs RST+: the MACULA number matches the RST+ number on the
  indicated Russian word in only 39.4 % (OT) / 38.7 % (NT) of records;
  the correct word is almost always 1–6 positions **earlier**; only
  ~12–13 % of verses are ≥ 90 % consistent. Publication commit
  `6473aa4` (2024-09-27) added the JSON and TSV together, so the ids
  were produced on a different tokenization of the same text.
**Conclusion (OQ 50):** RUSSYN cannot be used as gold or as a source
of the Synodal layer as published. Synodal goes through the pipeline
(phase 8.3, gold RST+ after the importer fix + ru_rob). Optional later
experiment: re-project RUSSYN records by order (monotonic shift) and
keep only verses that validate.

### G. MACULA ↔ TAHOT/TAGNT words (`g_macula_step.py`)

| Testament | MACULA words | by number | + by position in equal gaps | total |
|---|---|---|---|---|
| OT | 305 517 | 97.2 % | 8 164 | **99.9 %** |
| NT | 137 741 | 91.9 % | 10 199 | **99.3 %** |

NT gaps by number are form-vs-lemma numbering (G2076, G5213…).
**Conclusion:** MACULA data (Louw–Nida, referents, Clear alignments)
can be attached to base-layer words deterministically.

## Decisions taken from phase 1

1. Synodal tagging layer: pipeline, not Clear RUSSYN (OQ 50 closed).
2. Greek senses: MACULA Louw–Nida if the licence allows (OQ 51 closed,
   licence part stays in OQ 49).
3. Gate ceiling for content words ≈ 95 % (BSB tables ↔ Clear BSB);
   the evaluation normalizes NT form numbers to lemmas and scores
   function words separately.
4. Deterministic classic→dStrong resolution is the default in phase 6
   (96–98.5 % unique).

## Next steps

1. Phases 2, 3, 3b, 5 may start (in parallel) — needs the user's go.
2. Extend the form→lemma map beyond the 315 TBES links (from MACULA
   `strong` vs TAGNT `sStrong` on matched words, phase G output).
3. Freeze N and the `conf` combination rule before phase 7 (OQ 52).

## Log

- 2026-10-13 — Phase 0 done; sources pinned (`0825d0a`), ADR 0025
  (`bc2e31e`).
- 2026-10-13 — Phase 1 done: measurements A–G, scripts in
  `tools/strongs/measure/`, OQ 50/51 answered.
- 2026-10-13 — MACULA dependency licence audit (N1904, SBLGNT,
  MARBLE/SDBH, Clear's own data); conclusions in HANDOFF §4.3 and
  OQ 49; MARBLE analysis saved to `sources/strongs/legal/`.
- 2026-10-13 — New sources: `ubs-dictionaries` (official UBS open
  release under CC BY-SA — SDBH and revised Louw–Nida; legal channel
  for publishing domains/senses, codes match MACULA `@ln`) and
  `bdb-full` (full unabridged BDB, PD, 8,090 articles). Both pinned in
  sources.json with SHA-256, downloaded, MANIFEST rebuilt. `rsts.sb`
  module (swmail/RST, 66 books with Strong's) verified as Russian
  gold/prior; `token_of` bug confirmed (drops 2nd+ Strong's in
  `tokens` — spans intact).
- 2026-10-13 — BibleAquifer inventoried (71 repos, JSON+Markdown,
  mostly CC BY-SA). 21 sources pinned (all SHA-256) and downloaded.
  Key finds: **manual word-level RUSSYN→WLCM/SBLGNT alignment**
  (`rsb-aquifer`, 234,908 records, 66 books, CC0 — a publishable
  Russian gold), **ACAI** (mega-encyclopedia entities: relationships, labels in
  11 languages incl. Russian, MACULA-id referents, TIPNR crosswalk),
  `bdb-aramaic` (Aramaic BDB, CC0), `bdb-hebrew-aq` (BDB + sense-to-
  verse alignments), `aquifer-obd` (Tyndale OBD, Russian included),
  uW/FIA/Biblica key terms, UBS flora/fauna/realia lexicons, Manser
  Themes. `sources/aquifer/` holds the "own study Bible" track
  content (en+ru notes etc.). UW resources ship no Russian release
  assets (en only); `ubs-fauna/flora/realia` pulled md only — json
  assets carry hundreds of MB of media.
- 2026-10-13 — **Phase 2 done (v0.2.0)**: `strongs-step.sb` built by
  the Python pipeline `tools/strongs/lexicon/` (user approved Python
  over the Rust CLI plan — the spec's module/schema is the contract,
  not the emitter language; port later if it productizes).
  Numbers: `lex` 22,743 keys — 100 % of text-seen dStrong (17,025)
  plus TBESH/G LXX reserve; `lex_def` 55,084 rows across 7 licensed
  layers (`ubs-sdbh/sdgnt` CC BY-SA, `oshb-bdb` CC BY, `bdb-full` +
  `abbott-smith` PD, `bdb-hebrew-aq`/`bdb-aramaic` CC0); `morph`
  3,190 — 100 % of observed codes (457 via language-letter aliases);
  `entries` 26,011; TIPNR names on 4,438 keys; `sense_domain` (UBS)
  on ~16,300 keys; 12 keys flagged `ambiguous-base` for review.
  `module check` passes. Full report:
  `work/strongs/lexicon/report-phase2.md`.
  Decisions taken in-flight: base-level layers (UBS, bdb-full,
  bdb-aq, AS) are stored under the base key and joined via
  `lex_base` (no text duplication across lettered variants);
  aquifer alignments treated as candidate lists → article→base link
  by first `strongs-number` or majority base vote.
- 2026-10-13 — **Phase 2 self-audit**: a second pass over the built
  module found and fixed three issues. (1) UBS repeats one gloss
  across several `BaseForms` of the same entry (e.g. `G2590` ×4) —
  defs are now deduped on load; exact `(key, source, def)` dupes: 0,
  `lex_def` 55,084 → 54,959. (2) `G21370` was the only glossless row
  (empty Gloss column in TBESG for this LXX-reserve key) — marker
  `(no STEP gloss)` set. (3) Base-key entry cards (`H430`, `G2424`…)
  had the code as headword — now use the family representative's
  lemma (`אֱלֹהִים`, `Ἰησοῦς`), code stays in `norm`/text for search.
  Clarified, no fix needed: 3,296 `lex_base` bases without a `lex`
  row are normal — a base is a family normalization key, not a
  dStrong key; the linter warning "feature morph declared but no
  data" is a false positive (it looks for verse-level morphology,
  `morph` holds 3,190 rows). Still open for expert review: 12
  `ambiguous-base` keys (`lex.review` has candidates) and the rare
  `bdb-aramaic` majority-vote mislinks (one seen at `H9003`).
- 2026-10-13 — **Phase 5 done**: layer infrastructure + both known
  bugs fixed. (1) `token_of` collected only the first `strong=`/`morph=`
  span attr — now gathers all values space-separated (30,041 multi-
  Strong's spans in rsts keep their numbers; regression test added).
  (2) MyBible `attach_strong` overwrote consecutive `<S>` numbers —
  now appends `strong="…"` to the same `w` span (test added).
  (3) Core `studybible_core::text::words` tokenizer `w1` + CLI
  `studybible tokenize` (JSONL, `_meta` binding header; 31,163 verses
  on rsts). (4) `normalizeStrong` (app): dStrong `H0029G`, uW pad
  `G15100`→`G1510`, space-separated lists; raw-key-first lookup.
  (5) `links` table in SCHEMA + `Link`/`add_link`/`links()`/
  `has_links()` + lint rule (`strongs` counts `links` rows).
  (6) Pilot `engbsb-strongs.sb` (bin `strongs_layer`): 706,502 links
  from `bsb_tables.tsv`, `conf=10`, bound by
  `target_id`/`target_hash`/`tokenizer=w1`; `module check` clean;
  2,880 missed spans logged to `bsb-strongs.misses.tsv` (psalm
  superscriptions vs-0/vs-1, edition diffs). clippy `-D warnings` and
  the whole test suite are green.
- 2026-10-13 — **Phase 3 done**: `step-orig.sb` v0.1.0 built and
  checked (tools `tools/strongs/orig/`, report
  `work/strongs/orig/report-phase3.md`). Morpheme-level spans per
  ADR 0025 §3 concrete schema: `gr`/`strong`/`morph`/`lemma`/`wid`/
  `typ`/`ed`/`sns`/`eid`/`conj`/`mid`. 31,210 verses, 679,155 spans
  (OT 537,409 · NT 141,746); `mid` 512,853 (75.5%) — OT verses
  aligned 21,320/23,261, NT 7,647/7,949; remaining gaps are
  expected (X/R extra words absent from WLC, Ketiv-vs-Qere form
  differences, TR-only words absent from SBLGNT, punctuation
  morphemes). `eid` 45,131, `sns` 80,345. `module check` clean;
  Gen 1:1, John 1:1, Job 1:4 (Qere), 1Jn 5:7 (Comma Johanneum,
  `typ=K`/`ed=TR`) spot-verified. Open: 193 MB unpacked — blob
  packing (ADR 0022) is a pending optimization.
- 2026-10-13 — **Phase 3b done**: `knowledge.sb` v0.1.0 built and
  checked (tool `tools/strongs/knowledge/step01_build.py`, report
  `work/strongs/knowledge/report-phase3b.md`). 5,700 entities
  (person/place/concept/object/group/plant/creature/deity), 62,548
  names (12 locales + original lemmas + ru biblical titles), 12,527
  relationships, 114,214 verse_mentions in `eng` coordinates
  (USFM BookCode). Crosswalk: eid normalized to `Name@FirstRef`
  (all 4,205 ACAI eids resolved); strongs via eid→step-orig +
  lex-name + lemma→lex-core (5,067 entities = 89%); mentions from
  TIPNR names, ACAI references and MACULA referent ids. Spot checks
  Abraham/David/Herod/Jesus.2/Lord/Jerusalem/Leviathan pass.
- 2026-10-13 — **BSB layer v2: real dStrong** (`engbsb-strongs.sb` in
  `work/strongs/layers/`, builder `tools/strongs/layers/step_clear_bsb.py`).
  **The v1 pilot carried classic numbers — superseded.** Source chain:
  Clear manual alignments (WLCM-BSB + SBLGNT-BSB, CC BY 4.0) → MACULA id
  → `step-orig.mid` → dStrong; word-position `wid` fallback for maqef /
  textual gaps. 722,961 links = 99.3 % of w1 words; conf 10 → 614,976,
  8 → 96,996 (wid fallback), 4 → 10,989 (unresolved, strong empty).
  Token↔w1 mapping: SequenceMatcher + gap resolution (Clear `man's`
  ↔ w1 `man s`); 1,593 tokens unmapped (edition text diffs — Clear's
  BSB snapshot ≠ our bsb_tables text), logged `unmapped.tsv`.
  137 verses unaligned at source (psalm superscriptions, Neh 7:68).
  66,418 `diff` flags vs the classic layer → `engbsb-strongs.diffs.tsv`
  review channel. Spot checks: Gen 1:1 (`H9003 H7225G` on "In the
  beginning" — full morpheme coverage), John 1:1, 1Jn 5:7 clean.
  `module check` clean, 55.8 MB.
- 2026-10-14 — **Full cross-phase audit & rebuild (Phases 1–5)**:
  - **Phase 1/2 (`strongs-step.sb` v0.2.1)**: fixed `REF` regex to
    parse `[]`/`{}` bracketed refs in TAGNT (+350 NT rows, 0 missed
    lines across TAHOT/TAGNT); fixed `bdb-aramaic` attachment in
    `step04_lexdef_heb.py` (removed 90+ false articles from `H90xx`
    function morphemes); resolved all 12 `ambiguous-base` keys (`0`
    review rows remaining).
  - **Phase 3 (`step-orig.sb` v0.2.0)**: preserved Masoretic/source
    coordinates `sbcv`/`swid` from TAHOT brackets, matched WLCM by
    Masoretic verse via `SequenceMatcher` (ignoring maqef `־` and
    punctuation spans), and added `BGNT.tsv` fallback for Rom 16:25–27.
    Result: **31,219 verses, 679,505 spans, 606,231 direct `mid`
    (99.75 % of WLCM tokens; +93,378 `mid`)**.
  - **Phase 3b (`knowledge.sb` v0.2.0)**: mapped MACULA `mid` and ACAI
    `references` from Masoretic to `eng` versification (fixed ±1 verse
    shift across 2,094 OT verses, e.g. `PSA 3:0` vs `PSA 3:1`), joined
    559 UBS Fauna/Flora/Realia articles, and reduced `rel_dangling`
    from 64 to **1** (12,568 relationships, 112,610 mentions).
  - **Phase 5 (`engbsb-strongs.sb` v0.3.0)**: keyed `wid` fallback by
    Masoretic `(src_b, src_c, src_v, word_num)`, added `BGNT-BSB-manual`
    for Rom 16:25–27 and `bsb_tables`+`step-orig` fallback for 134
    unaligned verses (`PSA *:0`, `NEH 7:68`), and split `diff-shift`
    (29,724) from true lexical `diff` (8,551). Result: **724,445 links
    (99.51 % of w1 words); `conf=10`: 721,754 (99.63 %), `conf=9`:
    1,090, `conf=8`: 1,594, `conf=4` (`unresolved`): 7 words; 0
    unlinked verses**. Registered `lex`/`lex_def`/`lex_base`/`morph`/
    `knowledge` features in `studybible-cli` linter — all 4 modules pass
    `module check` with 0 warnings.
