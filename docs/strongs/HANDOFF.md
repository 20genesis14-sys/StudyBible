# Extended Strong's track — handoff spec

**English** | [Русский](HANDOFF.ru.md)

Status: plan approved by the user 2026-10-13. Decision record:
[ADR 0025](../adr/0025-extended-strongs-interlinear.md) (+ addendum in
[ADR 0024](../adr/0024-tree-of-knowledge.md)). This document is
self-contained: a new engineer or model with this file, the repository
and `STUDYBIBLE_DATA` must be able to continue the work without the
original conversation.

**Current status and measured numbers: [PROGRESS.md](PROGRESS.md)** —
read it right after this file; it overrides the expectations below
(e.g. Clear RUSSYN turned out unusable, phase 8.3 uses the pipeline).

---

## 0. Read first

- Repository: `D:\StudyBible` (master copy). **Never touch
  `D:\StudyBible-priv`.** `C:\StudyBible\StudyBible` is an outdated
  clone — do not use.
- Rules: `AGENTS.md` (docs before code, bilingual published docs,
  commit per directory, no push without the user, CI =
  `scripts\ci.ps1`). Source of truth for decisions: `docs/DECISIONS.md`.
- Do not start coding without an explicit user command; phases below
  are approved, but each phase start is confirmed with the user.
- External data lives in `STUDYBIBLE_DATA` = `D:\StudyBible-data`;
  never commit texts or modules. Python on this machine is `py`.
- Module format: `docs/spec/en/05-module-format-v1.md` (S-rules,
  optional tables S-20, packing `required="pack"` ADR 0022).
- Talk to the user in Russian; the user is not a programmer-linguist —
  explain results plainly.

## 1. Goals and non-goals

Goals (in order):

1. Universal extended Strong's lexicon (English) keyed by dStrong.
2. English interlinears (context + dictionary).
3. Strong's tagging pipeline for translations without tags; validated
   on English (BSB primary, KJV second) — **quality gate**.
4. Russian: overlay lexicon, dictionary interlinear, Synodal tagging
   layer; then other languages.
5. Tree of Knowledge stage 1 data (people, places) — ADR 0024.

Non-goals now: Septuagint (TAGOT not released), deuterocanonical books
(not in TAHOT/TAGNT; OpenBible Apocrypha interlinear is a later
option), runtime AI, full LSJ in the core lexicon.

100 % agreement with any gold is not expected: translations follow
different source texts (TR vs NA, Ketiv/Qere, missing verses).

## 2. Materials inventory

All under `D:\StudyBible-data\sources\strongs\` (pinned in
`data/sources.json`, re-fetch:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1 -Only <ids>`).
`MANIFEST.json` in that folder lists every file with SHA-256 and licence.
`sources.json` ids: `stepbible-data`, `oshb-lexicon`, `bsb-tables`,
`macula-hebrew`, `macula-greek`, `clear-alignments`,
`asv-alignment-data`, `asv-bible`, `openbible-geocoding`,
`abbott-smith`, `ubs-dictionaries`, `bdb-full` (≈ 1 GB) — plus the
BibleAquifer set (below). `macula-hebrew.tsv` is stored in Git
LFS upstream and is fetched from `media.githubusercontent.com`; the
Clear Alignments `catalog.tsv` stays an LFS pointer (not needed).
`-Pin` re-downloads everything it touches.

| id / folder | Content | Licence | Role |
|---|---|---|---|
| `stepbible` | STEPBible-Data: TAHOT ×4, TAGNT ×2, TBESH, TBESG, TFLSJ ×2, TEHMC, TEGMC, TIPNR, TVTMS, TTESV, README | CC BY 4.0; TTESV CC BY-NC; TBESH Meaning © Online Bible | core |
| `oshb-lexicon` | OpenScriptures HebrewLexicon: BrownDriverBriggs.xml, LexicalIndex.xml, AugIndex.xml, HebrewStrong.xml, schemas, PDF doc | CC BY 4.0 / PD | Hebrew definitions (default) |
| `bsb` | `bsb_tables.tsv` (Berean) | CC0 | primary gold + allowed input |
| `macula-hebrew`, `macula-greek` | MACULA TSV (WLC; SBLGNT + Nestle1904) | repos CC BY 4.0 © Biblica; `@ln`/`@domain` (MARBLE) and `@sdbh` (SDBH) — "used with permission" from UBS → **internal cross-check only, never ship in modules** | cross-check, Greek senses, referents, bridge to Clear |
| `clear-alignments` | Clear-Bible/Alignments: manual alignments eng BSB/YLT, rus RUSSYN, fra, spa, por, arb, hin, hau… | CC BY 4.0 | gold; RUSSYN possibly a direct source |
| `asv-alignment`, `asv-bible` | OpenBible ASV interlinear: rules, driver, reviewed judgments, USX aligned | code MIT, judgments no claim, ASV PD | process template + comparison gold |
| `openbible-geocoding` | places with coordinates | CC BY 4.0 | Tree of Knowledge |
| `abbott-smith` | Abbott-Smith Greek lexicon TEI | PD | Greek definitions, ML replacement |
| `esv/` (local, not re-fetchable) | `ttesv.txt`, `esv2016_*.sqlite`, `build_esv2016_strongs.py`, `make_variants.py`, `converter.py`, README, source JSON | ESV text © Crossway — never commit/distribute | ESV gold on held-out books |
| `ubs-dictionaries` | UBS Dictionary of Biblical Hebrew (from SDBH, ~99 % of OT words) and UBS Dictionary of NT Greek (revised Louw–Nida): senses, glosses, references, semantic domains; en JSON | **CC BY-SA 4.0** © UBS — the legal channel for publishing domains/senses | `lex_def` + domain field; `@ln`/`@sdbh` verification |
| `bdb-full` | full unabridged BDB (eliranwong), `DictBDB` JSON (8,090 articles keyed H…) + CSV with Strong's mapping | public domain | `lex_def` "deep article" level (alongside OSHB) |
| `bdb-aramaic` | Aquifer: BDB Aramaic section, `English-json`+`alignments` | CC0 | `lex_def` for Aramaic numbers H10xxx |
| `bdb-hebrew-aq` | Aquifer: BDB Hebrew, `English-json`+`alignments` | CC0 | `lex_def` + **alignments tag senses per verse** — a disambiguated-sense corpus |
| `rsb-aquifer` | Aquifer RussianSynodalBible: usfm/json + **234,908 manual word-level alignments WLCM/SBLGNT→RUSSYN** (all 66 books, `process=manual`, Burrito format, MACULA ids) | **CC0** | second Russian gold (alongside rsts), *publishable* — open licence; prior + gold for 8.3 |
| `acai` | Aquifer ACAI: entities people/places/deities/groups/fauna/flora/realia/keyterms — relationships, labels in 11 langs (incl. rus), referents keyed by MACULA ids, TIPNR crosswalk | CC BY-SA 4.0 © Mission Mutual | Tree of Knowledge (ADR 0024 add. 2026-10-13); lexicon name data and entity_names |
| `aquifer-obd` | Aquifer Open Bible Dictionary (Tyndale OBD adaptation) en+ru | CC BY-SA 4.0 (Tyndale→Mission Mutual) | entity articles, entity_names(ru) |
| `uw-tw`, `fia-keyterms`, `biblica-keyterms` | key-term articles uW / FIA / Biblica (en; FIA & Biblica also ru) | CC BY-SA 4.0 | Tree of Knowledge concept entities, term cards |
| `ubs-fauna`, `ubs-flora`, `ubs-realia` | UBS lexicons: animals, plants, realia (md) | CC BY-SA 4.0 © UBS | Tree of Knowledge fauna/flora/object entities |
| `dict-themes` | Dictionary of Bible Themes (Manser) | CC BY-SA 4.0 | Tree of Knowledge concept/event |
| `analysis/` | scripts used for the 2026-10-12/13 findings (`senses.py`, `compare.py`, `quality.py`, `q2.py`) | — | reproduce findings |

`D:\StudyBible-data\sources\aquifer\` also holds the "own study
Bible" track content (post-1.0): `aquifer-osn`, `biblica-notes`
(en+ru), `sil-tn`, `uw-tn`, `uw-tq`, `uw-tm` (en), `fia-tg`,
`uw-obs`, `video-bible-dict` — all CC BY-SA 4.0.

Already in `D:\StudyBible-data\modules`: `russyn.sb`, `rsts.sb`
(Synodal with Strong's from swmail/RST — **primary Russian gold and
whole-Bible prior**; licence unstated → internal use only; text is a
different 1876 edition, ~6 % real diffs vs `russyn`; rebuildable via
`module build --defs rstgit-defs.json`), `rstplus.sb`
(Synodal + Strong's, importer bug — §9), `ru_rob.sb` (23 books aligned,
Greek numbers uW format `G15100`), `eng-kjv2006.sb` (tokens packed in
`token_pack`), `engbsb.sb` (eBible tags shifted — not gold), `oshb.sb`,
`ugnt.sb`, `int_en.sb` (personal, no-distribute).

## 3. Data formats (verified facts)

**TAHOT** (tab-separated, data lines start with a ref):
`Eng (Heb) Ref & Type | Hebrew | Transliteration | Translation |
dStrongs | Grammar | Meaning Variants | Spelling Variants | Root
dStrong+Instance | Alternative Strongs+Instance | Conjoin word |
Expanded Strong tags`. Example: `Gen.1.1#01=L | בְּ/רֵאשִׁ֖ית |
be./re.Shit | in/ beginning | H9003/{H7225G} | HR/Ncfsa | … |
H9003=ב=in/{H7225G=רֵאשִׁית=: beginning»first:1_beginning}`.
Refs are in English versification with Hebrew in parentheses. Root in
`{}`; `/` separates morphemes; `H9xxx` = prefixes/suffixes/punctuation;
`_A`, `_B` = instance of the same word in a verse. Sense label after
`»` = TBESH sub-meaning of that dStrong (G→1, H→2…; exception H0776:
G=2, H=1). Person/place IDs appear as `LORD@Gen.1.1-Heb`,
`Abram»Abraham@Gen.11.26-1Pe`. 37 % of root tags in Gen–Deu carry a
sense label. Header explains Ketiv/Qere variant codes.

**TAGNT**: `Word & Type | Greek | English translation | dStrongs =
Grammar | Dictionary form = Gloss | editions | Meaning variants |
Spelling variants | Spanish translation | Sub-meaning | Conjoin word |
sStrong+Instance | Alt Strongs`. Example `Mat.1.1#03=NKO | Ἰησοῦ
(Iēsou) | of Jesus | G2424G=N-GSM-P | Ἰησοῦς=Jesus/Joshua |
NA28+NA27+Tyn+SBL+WH+Treg+TR+Byz | … | Jesus»Jesus|Jesus@Mat.1.1`.
Word type letters N/K/O mark NA/KJV(TR)/other presence; `editions`
lists editions.

**TBESH / TBESG**: `eStrong | dStrong (= relation, e.g. "H0776G = in
Hebrew of") | uStrong | Hebrew/Greek | Transliteration | Morph | Gloss
| Meaning`. TBESH: 11 682 rows, 9 345 eStrongs, 11 672 dStrongs (4 340
lettered). TBESG: 11 035 rows; NT range G1–G5624: 5 709 rows, 292
lettered dStrongs. Meaning sources in TBESG are tagged `(AS)`, `(ML)`,
untagged = STEPBible. **TBESH Meaning = Online Bible abridged BDB —
needs permission (OQ 48).**

**OpenScriptures HebrewLexicon**: `AugIndex.xml` `<w aug="1254a">bxy</w>`
→ `LexicalIndex.xml` `<entry id="bxy">…<xref bdb="b.cw.aa" strong=…/>`
→ `BrownDriverBriggs.xml` `<entry id="b.cw.aa">` with `<sense n=…>`,
`<def>`, `<ref r="Gen.1.1">`, `<status>` (base 6 395, ref 2 312, made
2 123, done 560, new 453). Mapping key: TBESH eStrong `H1254A` →
aug `1254a` (lower-case letter, no zero padding). 9 289/9 296 eStrongs
match; differences: 8106a/b, 8323a/b, 2428a, 1719c, 5867c.

**BSB tables** (`bsb_tables.tsv`, 23 columns): Heb Sort, Greek Sort,
BSB Sort, Verse, Language, WLC/Nestle Base (with edition marks
TR/RP/WH/NE/NA/SBL), …, Translit, Parsing ×2, Str Heb, Str Grk
(classic numbers), VerseId, Hdg, Crossref, Par, Space, begQ, BSB
version (English word/phrase), pnc, endQ, footnotes, End text.
Alignment is sometimes phrase-level ("the heavens" ↔ one word).

**Clear Alignments** (Scripture Burrito 0.3 JSON): `records[]` with
`source: ["o010010010012"]` (o/n + BB CCC VVV WWW P = MACULA word +
part), `target: ["01001001002"]` (BB CCC VVV WWW in the target TSV),
`meta.process = manual`. Target TSV `data/<lang>/targets/<ID>/*.tsv`:
`id, source_verse, text, skip_space_after, exclude, …`.
RUSSYN quick check: OT 182 340 / 434 855 target words aligned (41.9 %),
NT 89 248 / 129 477 (68.9 %); **13–14 % of aligned ids are
punctuation**; Gen 1:1 fine, Gen 1:2 inconsistent → measurement F.
Note: upstream `data/catalog.tsv` is a Git LFS pointer.

**ESV sqlite** (`esv/esv2016_strongs_step.sqlite`): `verses(id, book,
book_abbr, chapter, verse, text)`, `words(id, verse_id, seq, word_pos,
word, strongs)`, `unplaced(...)`. Strongs without prefix, comma-
separated; 7-digit numbers explained in `esv/README.md`. Content words
tagged 88.9 %, function words 18 %.

## 4. Decisions in force (summary of ADR 0025)

dStrong key; switchable definitions; dictionary interlinear primary;
tagging layer in target versification bound by id+hash+tokenizer; one
core tokenizer; `conf` 0–10 everywhere; pipeline with deterministic
first, model last (align → review → reconcile), agent per chapter,
provenance per chapter; English gate first; TTESV only on dev books;
held-out books; Tree of Knowledge feed; pinned sources. Read the ADR for
details.

### 4.1 Confidence scale `conf` (0–10)

| Score | Meaning | Action |
|---|---|---|
| 10 | Unambiguous: all checks agree, no alternative | auto-accept |
| 9 | Very confident: only wording differences | auto-accept |
| 8 | Confident with a caveat (polysemy, but sense confirmed) | accept, note in data |
| 7 | Probably right; some checks disagree | shown as **disputed** |
| 6 | Possibly right; plausible alternative exists | disputed + alternative shown |
| 5 | Unclear; two equal readings | manual review; shown as disputed |
| 3–4 | Probably wrong / violates rules | manual review; hidden by default |
| 0–2 | Error or no data | not published |

Always stored with `flags` (`polysemy`, `glossary_conflict`,
`sibling_clash`, `backtrans_mismatch`, `judge_low`, `name`,
`textual_variant`, `no_candidate`, `multi_candidate`…), `review`
(`auto|judge|human`), `source`, `notes`.

Signals: (1) agreement of independent variants (two runs or two
models); (2) back-translation vs English gloss + sense label;
(3) independent judge model score 0–10 with a fixed rubric; (4) rule
checks (glossary, siblings differ, uStrong-linked entries agree,
Synodal name forms, tag exists in verse and lexicon). Draft
combination (tune on dev books, freeze before held-out — OQ 52):
start at the judge score; −2 if variants disagree; −2 if
back-translation mismatches; cap at 4 on any hard rule violation;
cap at 7 if `polysemy` and no sense confirmation; deterministic
tagging decisions with eflomal posterior ≥ 0.9 and prior agreement
start at 9. Calibration (error rate per level, monotonic) is
measured in phase 7.

### 4.2 Held-out books

Ruth, Jonah, Ezra, Ps 1–41, Isa 40–55, Mark, Philippians, James,
Rev 1–5. Never an input in any form (no priors, no prompts, no rule
tuning). Everything else = development books.

### 4.3 Licence rules

Lexicon and base layer: only CC BY / CC0 / PD inputs. TTESV (NC) only
as priors on dev books → resulting layer `license=CC BY-NC`. ru_rob
(CC BY-SA) and RST+ (unclear) only as gold. ESV text never leaves
`STUDYBIBLE_DATA`. Every derived module carries attribution
(STEPBible "STEP Bible, www.STEPBible.org"; OpenScriptures; MACULA
"MACULA … Linguistic Datasets, available at github.com/Clear-Bible/…";
Clear Alignments contributors) and a list of our changes.

MACULA dependency audit (2026-10-13, details —
`sources/strongs/legal/marble-license-analysis.ru.txt`):

- Nestle1904: text, glosses (Berean), morphology/lemmas/Strong's —
  public domain; XML markup CC BY-SA → may be used if needed with
  attribution, but the derived module (or its part) is then licensed
  CC BY-SA. Currently unused: TAHOT/TAGNT are canonical.
- SBLGNT (Faithlife) — CC BY 4.0.
- Clear's own data (syntax, participant referents, semantic frames,
  synonyms, mappings) — CC BY 4.0 → optionally usable in the
  Tree of Knowledge with attribution.
- MARBLE `@ln`/`@domain` and SDBH `@sdbh` — "used with permission"
  from UBS, sublicensing scope unspecified → internal scoring only;
  MACULA attributes never ship in modules.
- **Legal publication channel exists** (2026-10-13): the same material
  is officially released by UBS under CC BY-SA 4.0 —
  `ubsicap/ubs-open-license` → `ubs-dictionaries` (Greek = Louw–Nida
  SDGNT, Hebrew = SDBH). Domain codes match MACULA `@ln` ("33.98"
  format). Published domain labels/senses come only from here; the
  derived module part is then marked CC BY-SA.
- semanticdictionary.org has a Russian MARBLE version — check in
  phase 8 as a source for Russian domain names and senses.

## 5. Phases, tasks, deliverables, acceptance

Order: 0 → 1 → (2, 3, 3b, 5 in parallel) → 4 → 6 → 7 (gate) → 8.
Mark progress in `docs/ROADMAP.md` (local) and record decisions in
`docs/DECISIONS.md`.

### Phase 0 — documents (done 2026-10-13)

ADR 0025, ADR 0024 addendum, DECISIONS, SPEC, OPEN-QUESTIONS (48–53),
ROADMAP, this spec, data pinned.

### Phase 1 — measurements (tooling: `tools/strongs/measure/*.py`)

Each measurement writes `STUDYBIBLE_DATA/work/strongs/measure/<X>.json`
plus a short Markdown summary for the user.

- **A. Classic → dStrong resolvability.** For each (verse, classic
  number) pair in BSB tables, KJV and ESV: count dStrongs in the
  corresponding TAHOT/TAGNT verse whose base equals the number.
  Output shares: exactly one / several / none. Expectation: most are
  unique.
- **B. Inter-gold agreement.** Word-level agreement on shared verses:
  BSB tables ↔ Clear BSB manual ↔ KJV ↔ TTESV (dev books for TTESV).
  Compare at classic-number level per target word after projecting
  each gold onto one tokenization by character offsets. Report
  content/function words, OT/NT. This is the ceiling for the gate.
- **C. Versification.** TAHOT/TAGNT refs ↔ `eng` ↔ `rsc` via
  `Versification::convert`; list ambiguous verses (candidates for
  `verse_map`).
- **D. Textual-basis gaps.** Share of BSB/KJV gold words whose number
  has no word in the base layer for that translation's edition (TAGNT
  `editions`; Ketiv/Qere in TAHOT).
- **E. Greek senses.** Inspect TAGNT "Sub-meaning" coverage and
  MACULA Louw–Nida domains; decide the Greek sense source (OQ 51).
- **F. Clear RUSSYN quality.** Find why aligned ids hit punctuation
  (re-tokenize Synodal several ways, compare with the TSV, check
  versions of the target text); sample 100 verses manually; if
  repairable, measure agreement with RST+ (after importer fix) and
  ru_rob. Decide: derive Synodal layer directly or not (OQ 50).
- **G. MACULA ↔ TAHOT/TAGNT word mapping.** Deterministic join per
  verse by lemma/Strong/order (WLC both sides; SBLGNT ⊂ TAGNT).
  Report coverage and conflicts.

Acceptance: all seven reports exist and are summarized for the user;
OQ 50/51 answered.

### Phase 2 — lexicon `strongs-step` — **done 2026-10-13 (v0.2.0)**

Status: built and accepted — see `report-phase2.md` in
`work/strongs/lexicon/`. Implementation note: done as the Python
pipeline `tools/strongs/lexicon/` (`step01`…`step07`, approved by
the user as a temporary compromise; the spec contract is the
module + schema below, not the emitter language — port to the
Rust CLI later only if it productizes). In-flight decisions:
base-level layers are keyed by base and joined via `lex_base`;
aquifer alignments are candidate lists → article↔base by first
`strongs-number`/majority vote; `features` lists the custom
tables (`entries,lex,lex_def,lex_base,morph`). 12 keys flagged
`ambiguous-base` pending review; TBESH `Meaning` not used.

Post-build self-audit (same day): deduped UBS defs (repeated glosses
across `BaseForms`) → `lex_def` 54,959; `G21370` (the only glossless
row — LXX reserve) marked `(no STEP gloss)`; base-key entry cards now
headworded by the family lemma (`אֱלֹהִים` for `H430`). `lex_base`
bases without a `lex` row are by design (base = family normalization
key, not a dStrong key). Open for expert review: the 12
`ambiguous-base` keys; rare `bdb-aramaic` majority-vote mislinks
(one seen at `H9003`).

CLI subcommand `studybible module lexicon-step <stepbible dir>
<oshb-lexicon dir> <abbott-smith dir> -o strongs-step.sb` (Rust, in
`apps/studybible-cli`, pattern: `src/bin/xref_layer.rs`; writer:
`crates/studybible-store/src/module.rs` `ModuleWriter`).

Schema (optional tables; also fill standard `entries` for generic UI and
FTS):

```
lex(key TEXT PRIMARY KEY,    -- dStrong 'H5414H'
    estrong TEXT, base TEXT, -- 'H5414', 'H5414'
    lang TEXT,               -- 'en'
    lemma, xlit, pos, gloss, -- Tyndale gloss
    sense_label,             -- '2_put;_set' (from TAHOT)
    sense_domain,            -- domain code from ubs-dictionaries (CC BY-SA); show labels only under that marking
    relation, related,       -- 'aramaic_of'|'name_of'|'combination', 'H0006'
    ustrong, source,
    conf INTEGER, flags TEXT, review TEXT)   -- English base: conf=10
lex_def(key, lang, def, def_source, def_license, conf, flags, review)
lex_base(base, key)          -- H5414 → H5414G…Q
morph(code, lang, short, long, conf)        -- TEHMC/TEGMC
meta: kind=dictionary, features=entries, id=strongs-step, license, attribution, sources
```

Definitions: Hebrew — OpenScriptures BDB via the chain in §3 (render
`<sense>` outline as numbered text, keep `<ref>`) plus optionally the
full BDB from `bdb-full` (`def_source='bdb-full'`) and UBS articles
from `ubs-dictionaries` (`def_source='ubs-sdbh'`, that module part is
CC BY-SA); Aramaic — `bdb-aramaic` (CC0, Aquifer); `bdb-hebrew-aq`
is a third BDB edition whose alignments map senses to verses; names —
TBESH/TIPNR biographies (the ACAI→TIPNR crosswalk helps); Greek —
Abbott-Smith +
STEPBible text + UBS Greek senses (`def_source='ubs-sdgnt'`,
LEXEntryCode = Louw–Nida codes); replace the 76 ML entries in
G1–G5624 + G6000–6099 by Abbott-Smith where present else gloss only
(`def_source='gloss-only'`). Add TBESH Meaning rows
(`def_source='OLB-abridged-BDB'`) **only if OQ 48 is granted**.

Separate optional `lsj.sb` from TFLSJ (`license` "CC BY-SA (Perseus
LSJ derivative)").

Acceptance: every dStrong occurring in TAHOT/TAGNT has a `lex` row;
every row has a gloss; every morphology code occurring has a `morph`
row; `module check` passes; unit test on 10 known keys (H0776G/H,
H5414G/H, H1254A, H0430G, G2424G, G4151G/H, H9003, G3056).

### Phase 3 — base layer `step-orig` — **done 2026-10-13**

Built in Python as `tools/strongs/orig/` (3 steps:
`step01_parse.py` TAHOT+TAGNT → `orig-words.jsonl`,
`step02_macula.py` WLCM/SBLGNT → `mid`, `step03_build.py` → .sb).
Concrete span schema is fixed in ADR 0025 §3: one `p` block per
verse, **one `w` span per morpheme**, span text = context English
gloss; attrs `gr`/`strong`/`morph`/`lemma`/`wid` (+`typ`/`ed`/`sns`/
`eid`/`conj`/`mid`). Result: 31,210 verses, 679,155 spans,
`mid` 512,853 (75.5%), `eid` 45,131, `sns` 80,345; `module check`
clean; report `work/strongs/orig/report-phase3.md`. Output:
`work/strongs/orig/step-orig.sb` (~193 MB unpacked; blob packing is
a pending optimization).

### Phase 3b — Tree of Knowledge stage 1 export — **done 2026-10-13**

Built in Python as `tools/strongs/knowledge/step01_build.py`.
Backbone is ACAI (`primary_id` = entity id): 5,700 entities, 62,548
names, 12,527 relationships, 114,214 `verse_mentions` in `eng`
coordinates (USFM BookCode, `seg=0`). Entity ids normalize to
`Name@FirstRef`; `entities.strongs` via three channels
(eid→step-orig, lex-name, lemmas→lex-core) — 89% of entities have
Strong's. Aquifer articles (OBD/FIA/Biblica) in `metadata.articles`,
ru names as `kind='biblical'`. Licence CC BY-SA 4.0. Report —
`work/strongs/knowledge/report-phase3b.md`.

### Phase 4 — English interlinears & layer reader in the app — **done 2026-10-14**

Implemented in `apps/studybible-flutter/rust/src/api/module.rs` and
`apps/studybible-flutter/lib/`:
- Context interlinear (TAHOT/TAGNT gloss column in `step-orig.sb`) and
  dictionary interlinear (`InterlinearMode.dictionary`: `dStrong` gloss
  + morphology code via `@dict_glosses:<book>` from `strongs-step.sb`),
  toggled by a segmented switch on the interlinear screen.
- Automatic Strong's layer injection (`inject_layer_strongs`) in
  `chapter_doc`: matches `target_id` + `target_hash` + `tokenizer="w1"`,
  replaces shifted legacy `strong="..."` attributes with `dStrong`/
  `conf`/`flags`/`ref` across multi-block poetry, and sets
  `layer_mismatch: true` when hashes diverge.
- Word tap/long-press opens the extended card (`@lex:...` +
  `@entity:...`): `strongs-step.sb` (`lex`, `lex_def` by `dStrong` and
  `base`, `morph`, `sense_domain` with CC BY-SA notice), contextual
  `sns` from `step-orig.sb` via `ref`, and `knowledge.sb` entity card
  with clickable relation chips.
- Verified end-to-end on Gen 1, Ps 23, John 1 in `test/bridge_test.dart`;
  `flutter analyze` and `cargo clippy -D warnings` clean.

### Phase 5 — layer format, core tokenizer, app, importer fixes — **done 2026-10-13..14**

Implemented (see DECISIONS «`links` table and the `w1` tokenizer»):
- `studybible_core::text::words(text) -> Vec<&str>` (`w1`,
  `WORDS_VERSION`): whitespace split, edge punctuation stripped,
  inner punctuation kept (`don't`, `son-in-law`, `3:00`), punct-only
  tokens take no index. CLI `studybible tokenize <module.sb>` →
  JSONL `_meta` + `{book, chapter, verse, words:[…]}` per verse.
- `links(book_id, chapter, verse, word, ref, strong, conf, flags,
  source)` in SCHEMA + `Link`/`add_link`/`links()`/`has_links()`;
  binding meta `target_id`/`target_hash`/`tokenizer`.
- Importer fixes done: `attach_strong` appends
  `strong="H1254" strong="H853"` to the same `w` span (was: last tag
  won); `token_of`/`attr_all` collects every `strong=`/`morph=` value
  space-separated (was: first only — 30,041 rsts spans affected).
- Flutter `normalizeStrong`: `H0029G` (+canon `H29G`), uW `G15100`,
  space-separated lists; search tries the raw key first.
- Layer reader application in `chapter_doc` (conf 5–7 → wavy accent
  underline "disputed", `aux` → muted dotted underline, `layer_mismatch`
  banner on hash mismatch) — done in Phase 4 (2026-10-14).
- Pilot `engbsb-strongs.sb` via `apps/studybible-cli/src/bin/
  strongs_layer.rs` (bsb_tables.tsv → 706,502 links, `conf=10`;
  misses logged in `bsb-strongs.misses.tsv`; `module check` clean).
- **v0.4.0 (Phase 5b — supersedes pilot, v2, v0.3.0):**
  `work/strongs/layers/engbsb-strongs.sb` via
  `tools/strongs/layers/step_clear_bsb.py` — real dStrong from Clear
  manual alignments (`WLCM-BSB`, `SBLGNT-BSB`, `BGNT-BSB` for Rom
  16:25–27) through `step-orig.mid` (606,231 direct `mid` in
  `step-orig` v0.2.0), Masoretic `wid` fallback,
  `bsb_tables`+`step-orig` fallback (`PSA *:0`, `NEH 7:68`, and 1,006
  edition-diff words), and intra-group splitting (`split_group` into
  `head` / `aux` / `added`). **728,034 links (100.00 % of w1 words)**;
  `conf=10`: 723,139 (99.33 %), `conf=9`: 3,294, `conf=8`: 1,594,
  `conf=4` (`unresolved`): 7 words; single-dStrong words: 582,515
  (80.0 %); `diff` review channel (`engbsb-strongs.diffs.tsv`, 8,475
  lexical diffs).
  Note: `bsb_tables.tsv` carries classic numbers, not dStrong.
Acceptance met: clippy `-D warnings` clean, suite green, regression
tests for both importer/reader fixes.

### Phase 6 — tagging pipeline (`tools/strongs/pipeline/`) — **done 2026-10-14**

Implemented in `tools/strongs/pipeline/` (`priors.py`, `contour1.py`,
`contour2.py`, `build_layer.py`) + skills in `.devin/skills/` and
`tools/strongs/skills/` (`strongs-verse-align`, `strongs-review`,
`strongs-chapter-reconcile`):
- `studybible tokenize --with-spans <module.sb>` exports per-word `w1`
  styles and embedded attributes across both `spans` and `span_pack`.
- `priors.py` builds `work/strongs/pipeline/priors_en.json` strictly on
  **dev books** (excluding all held-out books of §4.2): 359 `form_alias`
  entries, 19,570 `classic -> dStrong` mappings, and 23,217 word priors.
- `contour1.py` + `contour2.py` + `build_layer.py` support both
  `--mode assisted` (lifts classic Strong's + `\add` + `form_alias` +
  `H9xxx`/`G3588` function morphs) and `--mode blind` (aligns untagged
  `w1` words using `step-orig` glosses, `strongs-step` definitions, and
  dev-book priors), resolves intra-verse polysemy, reconciles chapters,
  writes chapter receipts `runs/<target>/<BOOK>.<ch>.json` with
  `--resume`, and builds `.sb` layers (`eng-kjv2006-strongs.sb`:
  790,715 links, 100 % `w1` coverage, `module check` clean).

| Step | Action | Model |
|---|---|---|
| 1 | words via `studybible tokenize` | no |
| 2 | verse mapping target → `eng` | no |
| 3 | candidates = base-layer words of the verse(s), filtered by edition of the translation (BSB/ASV eclectic, KJV TR…) | no |
| 4 | eflomal over the whole Bible: target words/lemmas ↔ dStrong tokens, posteriors | no |
| 5 | lexical priors: BSB tables, TTESV (dev books only) for English; own glosses for other languages | no |
| 6 | combine → decision + preliminary `conf` | no |
| 7a | **align** unresolved words (skill `strongs-verse-align`) | yes |
| 7b | **independent review** per verse (skill `strongs-review`) → 0–10 | yes |
| 7c | **chapter reconcile** (skill `strongs-chapter-reconcile`) | yes |
| 8 | validate (tag ∈ verse ∧ lexicon), final `conf`, footnotes, stats | no |

Run as an **agent per chapter**. Per chapter write
`STUDYBIBLE_DATA/work/strongs/runs/<target>/<BOOK>.<ch>.json`:
model+version, rules version+hash, date, per-word decisions with
`conf/flags/source`, review receipts. Resumable: skip chapters whose
record exists and whose rules hash matches. Start rules from
`asv-alignment/config/alignment-instructions-{hebrew,greek}.md`.

### Phase 7 — English evaluation (gate) — **passed 2026-10-14**

Evaluated on the 9 held-out corpora (`RUT`, `JON`, `EZR`, `PSA 1–41`,
`ISA 40–55`, `MRK`, `PHP`, `JAS`, `REV 1–5`) via
`tools/strongs/pipeline/evaluate_gate.py` (report —
`work/strongs/report-phase7-en-gate.md`, raw JSON —
`work/strongs/pipeline/gate_phase7.json`, `N = 2.0 pp` frozen, OQ 52
closed):
- **BSB Mode A (`engbsb-strongs.sb` v0.4.0 vs `bsb_tables`):** content
  F1 = **97.52 % OT / 96.73 % NT** (+2.32 pp / +1.33 pp above inter-gold
  ceiling `B = 95.2 % / 95.4 %`), function F1 = **96.98 % OT / 96.78 %
  NT**, proper names = **98.90 %** (`n = 2,372`).
- **KJV Mode B (`eng-kjv2006-strongs.sb` v0.1.0 vs KJV + `step-orig`):**
  content F1 = **100.0 % OT / 99.99 % NT** (`dStrong` accuracy **99.97 %
  OT / 99.99 % NT**), proper names = **99.96 %** (`n = 2,380`).
- **Blind Mode C baseline (no input tags, dev-only priors):** content F1
  = **82.10 % OT / 80.41 % NT**, proper names = **97.04 %**, `conf=10`
  slice (63 % of words) accuracy = **94.32 %**, strictly monotonic error
  rates across `conf = 10 → 9 → 8 → 7` (`5.68 % < 26.24 % < 32.96 % <
  64.47 %`). **Gate passed — cleared for Phase 8 (Russian).**

| Translation | Gold | Allowed inputs |
|---|---|---|
| BSB (primary) | BSB tables; Clear BSB manual | TTESV dev books |
| KJV | its own tags | BSB tables, TTESV dev books |
| ESV | TTESV held-out books | BSB tables |
| ASV (comparison) | OpenBible ASV interlinear | as KJV |

Metrics: precision/recall/F1 on (word, classic number) and (word,
dStrong) pairs; content vs function words; OT/NT; proper-name dStrong
accuracy vs TIPNR; **calibration** (error rate per `conf` level);
share of words sent to the model; tokens/cost per chapter;
textual-basis differences listed separately. Project gold onto `w1`
tokens by character offsets. Gate (freeze N first, OQ 52):
F1(content, held-out) ≥ inter-gold agreement (B) − N; names ≥ 95 %;
calibration monotonic. **Fail → no Russian.**

### Phase 8 — Russian (after the gate) — **done 2026-10-14**

Implemented in `tools/strongs/pipeline/prep_rlob.py`,
`tools/strongs/pipeline/build_ru_layers.py`,
`tools/strongs/lexicon_ru/build_lexicon_ru.py`, and
`tools/strongs/knowledge/step02_ru_names.py`:
- **8.0 Modern Russian open corpora (`door43-ru`, CC BY-SA 4.0):**
  fetched `ru_rlob` (v13.0, 31 books), `ru_rsob`, `ru_tw` (1,018 Russian
  Translation Words articles), `ru_twl`, and `ru_tn`; built
  `modules/ru_rlob.sbz` and rebuilt `modules/ru_rob.sbz` cleanly
  (preserving nested `\zaln-s` prefixes and normalizing 5-digit uW Greek
  codes `G15100 → G1510`).
- **8.1 `strongs-step-ru.sbz` (`v0.1.0`):** 22,743 `dStrong` entries in
  `lex` with modern Russian glosses (19th-century Synodal archaisms like
  *мытарь, выя, чресла, наипаче* modernized with `(в Син.: …)` notes),
  3,190 Russian `morph` descriptions, and 63,950 `lex_def` entries
  (`door43-tw-ru`, `corpus-ru` usage across RLOB/ROB/Synodal, and UBS
  SDBH/SDGNT + OSHB layers).
- **8.2 Russian dictionary interlinear & cards in the app:** Rust bridge
  (`find_lex_module`) and Flutter UI automatically use
  `strongs-step-ru.sbz` when `settings.lang == 'ru'`.
- **8.3 Three Russian `dStrong` layers:**
  - `russyn-strongs.sbz` (570,826 links, 100 % `w1` coverage of
    `russyn.sb`, `rsc ↔ eng` mapped via `verse_map.json`);
  - `ru_rlob-strongs.sbz` (202,958 links, 100 % `w1` coverage of
    `ru_rlob.sb`);
  - `ru_rob-strongs.sbz` (557,946 links, 100 % `w1` coverage across all
    66 books of `ru_rob.sb`, including the 43 OT books lacking `\zaln`).
- **8.4 `knowledge.sbz` Russian names:** added 3,488 Synodal
  (`kind='synodal'`) and modern biblical (`kind='biblical'`) Russian
  entity names to `entity_names`. All modules pass `studybible module
  check`.

- **8.1** `strongs-step-ru.sb` via skill `lexicon-translate`: dStrong
  glosses + sense labels, morphology table, glossary; names last (from
  8.3, Synodal forms); full definitions only after OQ 48 (translate
  once from the chosen source). Every row has `conf`. Expert sample by
  frequency + all rows with `conf ≤ 7`.
- **8.2** Russian dictionary interlinear (no model): base layer + ru
  glosses + ru morphology; disputed marks visible.
- **8.3** Synodal (`russyn`): phase-6 pipeline; gold —
  **`rsb-aquifer` (manual word-level alignment RUSSYN→WLCM/SBLGNT,
  234,908 records, all 66 books, CC0 — publishable)** and **`rsts`
  (66 books with Strong's from swmail/RST; read numbers from
  `spans.attrs` until `token_of` is fixed; licence unstated —
  internal only)** + fixed RST+ + ru_rob; word→classical prior from
  `rsts` and the Aquifer alignment. Clear RUSSYN excluded (broken,
  measurement F). Text editions diverge (~6 % in rsts — check the
  Aquifer edition separately); divergent verses get an edition flag
  and are excluded from scoring. Expert sample 200–300 verses.
- **8.4** Tree of Knowledge `entity_names` (ru) from the Synodal layer.

Next languages: glosses + morphology with `conf`, dictionary
interlinear, pipeline on the main translation, gold = Clear manual
alignment where available (fra LSG, spa RV09, por, arb, hin, hau…).

## 6. Skills (to be created when phases 6/8 start)

A skill = instruction file + scripts. For Devin place them in
`.devin/skills/<name>/SKILL.md`; for other agents keep the same text in
`tools/strongs/skills/<name>.md`. Prompts and rubrics are **frozen
before** held-out measurement; changes bump the rules version.

### 6.1 `strongs-verse-align` (step 7a)

Input per chapter (JSON): for each verse — numbered target words
(`w1`), candidate original words (address, surface, translit, dStrong,
gloss, sense_label, morph, editions), current deterministic proposals
with preliminary `conf`, alignment rules. **No gold.** English helper
text only for non-English targets and only from CC BY/CC0/PD sources
(BSB) — never ESV text in prompts for published layers.
Output schema: `{verse, links:[{word, refs:[address…] | [], role:
"head"|"part"|"added", conf_self:0-10, note}]}`. Hard rules: refs only
from the verse's candidates; every candidate either linked or marked
`untranslated` with reason; one target word may link several refs
(phrases) and vice versa.

### 6.2 `strongs-review` (step 7b; also judge for 8.1)

Independent of 6.1 (different model or fresh context). Input: verse,
candidates, proposed links (or proposed translation for lexicon
entries). Output `{item, score:0-10, problems:[flag…], alternative}`.
Rubric = §4.1 table; must justify any score ≤ 7.

### 6.3 `strongs-chapter-reconcile` (step 7c)

Input: whole chapter decisions + review results. Tasks: find
inconsistent treatment of the same word/phrase, propose rule changes
(recorded with a new rules version), re-queue verses. Output: list of
changed links with reasons + proposed rule diffs.

### 6.4 `lexicon-translate` (phase 8.1, any language)

Batch = ~50 entries grouped by root/uStrong. Input: key, lemma,
English gloss, sense_label, siblings' glosses, definition (chosen
source), glossary for the language, name policy. Output per entry:
`{key, gloss, def?, alt?, conf_self, flags, note}`. Then two variants
compared, back-translation, `strongs-review` judge, rule checks →
final `conf` (§4.1).

## 7. Known facts and numbers (for orientation)

- ESV vs Russian per-verse Strong's set agreement: ru_rob OT 92.8 % /
  NT 82.3 % (ESV set covered); RST+ ~79 %. BSB(eBible) only 69 %.
- RST+ importer loses numbers on 6.8 % of tagged words.
- OpenScriptures BDB vs TBESH Meaning: TBESH more complete for ~half
  of common words (sense outlines), BDB longer in 52 % (full entries,
  2 878 with scripture refs); names richer in TBESH (STEPBible bios).
- OpenBible ASV interlinear: whole Bible ≈ 2.5 B tokens, ~$300 on
  subscriptions (list ≈ $7 800); gold in prompts was a distraction.
- STEPBible repo is updated almost daily — always re-pin deliberately
  and diff.

## 8. Open questions

See `docs/OPEN-QUESTIONS.md` 48–53 (Online Bible permission, ML/MARBLE
licences, RUSSYN quality, Greek senses, gate numbers, STEPBible
upcoming data).

## 9. Code pointers

- Module writer: `crates/studybible-store/src/module.rs`
  (`ModuleWriter`); layer examples: `apps/studybible-cli/src/bin/
  xref_layer.rs`, `strongs_layer.rs` (`links` table writer);
  CLI: `apps/studybible-cli/src/main.rs` (`tokenize` — `w1` words).
- Versification: `crates/studybible-core/src/versification.rs`
  (`convert`, `convert_mapped`); word tokenizer `w1`:
  `crates/studybible-core/src/text.rs` (`words`, `WORDS_VERSION`).
- Fixed 2026-10-13 (regression tests in place): MyBible
  `attach_strong` (consecutive `<S>` merge); `token_of`/`attr_all`
  (every `strong=`/`morph=` collected space-separated — rsts 30,041
  multi-Strong's spans keep all numbers; `token_pack` codec
  unchanged).
- Flutter lexicon: `apps/studybible-flutter/lib/lexicon.dart`
  (`normalizeStrong`: dStrong `H0029G`, uW `G15100`, lists;
  overlay logic used by the Tsygankov dictionary).
- Python module writer example (schema + `content_hash`):
  `scripts/build-interlinear.py`.
- Data fetch: `scripts/fetch-data.ps1` (`-Only`, `dest`, `files`),
  `data/sources.json`.
