# 0024. The Biblical mega-encyclopedia — the `knowledge.sb` module

**English** | [Русский](0024-mega-encyclopedia.ru.md)

Status: design accepted (2026-10-12); **stage 1 built 2026-10-13..14** —
`knowledge.sb` v0.2.0 + Phase 8.4 with ACAI + TIPNR as the entity backbone
(**14,554 entities**, **51,527 names** incl. 3,488 Synodal & modern Russian
forms, **26,654 relationships**, **114,046 verse_mentions**, **9,233
articles**, 89 % `dStrong` coverage; see `work/strongs/knowledge/report-phase3b.md`
and DECISIONS "ACAI as the entity backbone").

## Context

The goal is quick access to entities related to the verse being read
(people, places, objects, customs, concepts, events): an entity card,
its relations, a list of mentions, articles and media — independent
of any particular translation and fully offline.

Format v1 already allows this without forks: optional tables and
`meta` keys are ignored by older readers (C-18), and text-less layer
modules already exist (ADR 0016 `kind="layer"`, ADR 0023 — the shared
cross-reference layer). The mega-encyclopedia is the same kind of
independent layer, but with its own composition contract, so it gets
a dedicated `kind`.

## Decision

1. **Module `knowledge.sb`** — an `.sb` with `meta.kind="knowledge"`,
   shared by all translations; no books or verse text of its own
   (`books` empty, like `layer`/`dictionary`). Attached optionally:
   without the file the app simply shows no layer.
2. **Schema** (all tables optional per v1 rules):

   - `entities(id PK, type, subtype, name, name_original, strongs,
     short_description, article, metadata JSON, image_path, source)` —
     entity type as text (`person`, `place`, `object`, `custom`,
     `concept`, `event`, `creature`, `plant`, `material`, `title`);
     subtype via `subtype` + `type_hierarchy`.
   - `entity_names(entity_id, name, lang, kind)` — names and synonyms
     in a separate table (instead of a JSON `aliases` field): FTS over
     names, multilingual support, `kind` = canonical/alias/biblical form.
   - `relationships(id PK, from_entity_id, to_entity_id, relation_type,
     book, chapter, verse, seg, description, weight, source)` — a relation
     between entities; the anchor verse as `(book, chapter, verse, seg)`
     coordinates, `NULL` = no verse anchor.
   - `verse_mentions(book, chapter, verse, seg, entity_id, mention_type,
     context, source)`, PK `(book, chapter, verse, seg, entity_id)` —
     an entity mentioned in a verse; the main "verse → entities" path.
   - `type_hierarchy(parent_type, child_type)` — the type taxonomy for
     validation and UI filtering/grouping; extended by data, no schema
     migrations.
   - `media(id, entity_id, type, rel_path, caption, order_idx)` —
     images/maps/diagrams, paths relative to the module.
   - `embeddings` — optional and later (semantic search over verses
     and articles).
3. **Coordinates use canonical codes, not local ids**: the book in a
   coordinate is the textual `book` (`BookCode`: `GEN`, `PSA`, `1SA`),
   plus `seg` — the verse-part segment (0 = whole verse, 1..26 = a..z).
   A `kind="knowledge"` module has an empty `books` of its own, so a
   local `book_id` could not even be resolved there — the rule
   "public coordinate = `(BookCode, chapter, verse, segment)`"
   applies (DECISIONS). Coordinates are stored in the `eng`
   versification; conversion to the open module's versification
   happens at read time via `Versification::convert`. For places
   where automatic conversion is ambiguous or diverges, an optional
   manual mapping table `verse_map` exists.
4. **Provenance is mandatory**: a `source` field on entities,
   relationships and mentions (`TIPNR`, `OpenBible`, dictionaries,
   `user`…). Versioning via `meta` (`content_version`, `updated_at`);
   the mega-encyclopedia updates independently of translations.
5. **Ties to existing data**: `entities.strongs` ↔ `tokens.strong`
   of modules with `features=strongs`; enriching `x`-spans with
   entities is a separate deferred step.
6. **Staging**:
   - Stage 1: people and places (TIPNR + OpenBible — data already
     structured and license-clean), tables `entities`,
     `entity_names`, `relationships`, `verse_mentions`,
     `type_hierarchy` + a minimal entity card in the UI.
   - Then: `object`/`custom` → `concept`/`event` → nature/materials;
     articles grow from `short_description`; then `embeddings`
     and `media`.
   - AI is used only at data-preparation time (draft articles and
     relations), never at runtime.

## Deferred possibilities (outside this ADR)

- User annotations on top of the base module
  (`user_knowledge.sb`, `source='user'`, priority on conflicts).
- Place coordinates (`lat`/`lon` in `metadata`) and a map layer.
- Enriching existing `x`-spans with mega-encyclopedia entities.

## Consequences

- Format v1 changes nothing structurally: a new `meta.kind` value and
  a fixed set of optional tables are added; older readers simply do
  not see the module.
- The mega-encyclopedia is not duplicated per translation — one module for all,
  updated independently (like `openbible-xrefs`, ADR 0023).
- The effort concentrates in the data: `person`/`place` are covered
  by ready sources, while `concept`/`event` need authored content —
  the main risk and the reason for staging.
- Books in coordinates are addressed by `BookCode`, not local
  `book_id`: the module has no `books` of its own, so a numeric id
  would have nothing to resolve against. Compatibility of the code
  set with translation modules is checked by `module check`.

## Addendum 2026-10-13 — ADR 0025 (extended Strong's)

- `entities.strongs` holds **disambiguated Strong's numbers**
  (dStrong, e.g. `H0029H` — a specific person named Abijah), not
  classic numbers; classic numbers resolve through the lexicon's
  `lex_base`.
- Stage 1 sources are extended: the person/place IDs on every
  TAHOT/TAGNT word (`Abraham@Gen.11.26-1Pe`, carried into the
  `step-orig` base layer) give **word-level** `verse_mentions`
  (`source='STEPBible'`); TIPNR gives entities and family relations;
  OpenBible Geocoding gives `lat`/`lon`; MACULA participant referents
  are an optional extra source (`mention_type='referent'`).
- Localized `entity_names` (e.g. `lang='ru'`, `kind='biblical'`) are
  taken from Strong's tagging layers of the main translation of that
  language (Synodal for Russian), and translation text can highlight
  mentions through those layers.
- Later concept sources: MACULA semantic domains (licence to verify),
  OpenBible Topical Bible (CC BY), Manser's Dictionary of Bible Themes
  (CC BY-SA), STEPBible TBCWG when released.

## Addendum 2026-10-13 — BibleAquifer as a content source

The `github.com/BibleAquifer` organization (~73 public repos) publishes
ready datasets in JSON + Markdown (language folders; Russian `rus`
present for the Biblica resources), mostly CC BY-SA 4.0:

- **`ACAI` — the most important find**: word/phrase-level entity
  annotations in the original languages for people, places, deities,
  groups, fauna, flora, realia and keyterms — with preferred labels,
  descriptions and **inter-entity relationships**. Record shape
  (`id`/`primary_id`/`referred_to_as`, `person:Aaron`-style ids) maps
  almost directly onto `entities`/`entity_names`/`verse_mentions`/
  `relationships`; for word-level mentions it is an analog of the
  TAHOT/TAGNT person/place IDs. CC BY-SA © Mission Mutual.
- **Entity-type coverage that earlier had no source**: `UBSFloraLexicon`
  (`plant`), `UBSFaunaLexicon` (`creature`), `UBSRealiaLexicon`
  (`object`/`custom`/`material`), `BiblicaStudyNotesKeyTerms` and
  `FIAKeyTerms` (`concept`, localized articles), `DictionaryBibleThemes`
  (`concept`/`event`), `AquiferOpenBibleDictionary` and
  `UWTranslationWords` (all types — people/places/terms),
  `UBSHebrewDictionary`, `UBSGreekNTDictionary`, `BDBHebrewLexicon`,
  `BDBAramaicLexicon` (articles/`name_original`, `strongs` cross-links).
- **Media for `media`/`image_path`**: `BiblicaOpenBibleMaps`,
  `FIAMaps`, `FIAImages`, `UBSImages`, `VideoBibleDictionary`.
- **Original-language texts**: `WestminsterLeningradCodex`,
  `SBLGNT`, plus `text-align` — relevant to the interlinear/tokens
  track, not the mega-encyclopedia directly.
- **Licence note**: Biblica study-notes content is CC BY-SA 4.0
  (© Biblica Inc. 2023; adaptations © Mission Mutual) — attribution
  required, derived modules stay under CC BY-SA, entries go to
  MODULE-LICENSES. The NIV *text* itself is proprietary and is not
  on Aquifer; `BiblicaOpen*` covers Arabic/Chinese/Nepali/Indonesian
  only — no English. Notes are verse-anchored (`book/chapter/verse`),
  not translation-anchored, which matches the layer-coordinate model.
- **Format docs for converters**: the `docs` repo pins the JSON
  schemas (`aquifer_resource.schema.json`, `aquifer_article.schema.json`,
  alignment docs); `aquifer-api-client` is a ready Python client.
- Related track (not this ADR): `BiblicaStudyNotes` +
  `AquiferOpenStudyNotes` (Tyndale notes, adapted) + BookIntros +
  dictionaries are the content base of the future "own study Bible"
  — see ROADMAP (local).

## Addendum 2026-10-14 — Stage 2+ refinements (articles, naming, chronology, ranking, atlas)

1. **Separate `entity_articles` table instead of JSON `metadata.articles`**:
   as multiple dictionaries join the module (Aquifer OBD, FIA, Biblica
   KeyTerms, UBS Realia/Flora/Fauna, user-imported lexicons), each
   entity accumulates several articles across sources and languages.
   Storing them in `entity_articles(entity_id, source, lang, title,
   body_md, license, ord)` (optional table) enables FTS5 over article
   bodies, avoids parsing large JSON blobs when opening a card, and
   lets the UI switch sources/languages via tabs. `entities.article`
   stays as the default summary fallback.
2. **Synodal and traditional name forms in `entity_names`**: modern
   Russian translations of Aquifer/ACAI resources often use
   contemporary transliterations (*Синахериб*, *Бет-Эль*) that diverge
   from the Synodal tradition (*Сеннахирим*, *Вефиль*, *Иисус Навин /
   Осия*). Once the Synodal tagging layer (`russyn-strongs`, ADR 0025)
   is built, Russian word forms grouped by `eid`/`dStrong` are
   lemmatized to nominative singular and injected into `entity_names`
   (`lang='ru'`, `kind='biblical'`, `source='russyn-layer'`) so search
   and card headers match the text the user is reading.
3. **Chronology and timeline (`event` and dates)**: `entities`
   (primarily `event`, `person`, rulers' reigns) gains optional date
   bounds (`year_start`, `year_end` as signed astronomical years with
   an approximation flag, in `metadata` or columns). Primary open
   source: **Theographic Bible Metadata** (CC BY-SA), which links
   events, people, periods and verses to a chronological axis.
4. **IDF × `mention_type` ranking for verse chips**: with ~114k
   `verse_mentions` (including pronouns and subjects), verses can list
   many entities at once. Queries and the UI sort mentions by
   `IDF(entity) × weight(mention_type)` so rare, specific entities in
   the verse (e.g. *Melchizedek*) always precede ultra-frequent
   background entities (*God*, *Israel*, *Jerusalem*).
5. **Interactive offline atlas**: alongside static map images
   (`BiblicaOpenBibleMaps`, `FIAMaps`), the map layer can ship a
   compact offline vector basemap of the Near East / Mediterranean
   (PMTiles / MapLibre, ~5–10 MB with relief) and plot the current
   chapter's places dynamically from `knowledge.sb` coordinates
   (OpenBible Geocoding `lat`/`lon`) with tap-through to entity cards.
6. **Two-step homonym-safe entity resolution via `links.ref → step-orig.eid`**
   (implemented in Phase 4): biblical names often share a single Strong's
   number across many distinct people (e.g. multiple Zechariahs, Herods,
   Marys). When a user taps a word in any translation with a Strong's
   layer (`{id}-strongs.sbz`), the reader first resolves `links.ref`
   (`wid = Psa.3.0#10`) against `step-orig.sb` (indexed by `book_id,
   chapter`) to obtain the exact disambiguated `eid` (`Absalom@2Sa.3.3`)
   and looks up that specific entity in `knowledge.sb`, falling back to
   `entities.strongs` only when `eid` is absent.
7. **Structured illustrated Profile Cards ("Entity Passport") & Media layer**:
   instead of a plain wall of text, the entity card uses a structured
   visual passport layout:
   - **Header banner**: accent category & role badge (*"PERSON · King of
     Israel, Psalmist"* / *"PLACE · City in Judah"*), primary localized
     title (`David · Давид`), original-language name and etymology/meaning.
   - **Structured key-value rows with dividers**:
     - *Who / What*: concise 1–2 sentence summary (`short_description`,
       localized to modern Russian and English);
     - *Family & Relations*: grouped by relation type (*Father*,
       *Mother*, *Spouse*, *Siblings*, *Children*, *Tribe/Group*) as
       interactive navigation chips;
     - *Era & Geography*: chronological bounds (`year_start..year_end`)
       and region/coordinates;
     - *Key Events & Verses*: top ranked Scripture references.
   - **Bottom-right / header illustration (`media` & `image_path`)**:
     - **Places (`place`)**: **2,424** geo-linked photographs and
       thumbnails from `openbible-geocoding/data/image.jsonl` (Wikimedia
       Commons CC BY-SA / PD, with `thumbnail_url_pattern`, credit, and
       color placeholders) plus `BiblicaOpenBibleMaps` and `FIAMaps`;
     - **Plants, animals, objects & realia (`plant`, `creature`,
       `object`, `custom`)**: **757** illustrations referenced in
       `UBSFloraLexicon` (202), `UBSFaunaLexicon` (160), and
       `UBSRealiaLexicon` (395) (`BibleAquifer/UBSImages` `PTZ-*`,
       `WEB-*`, CC BY-SA 4.0) plus `FIAImages`;
     - **People (`person`)**: book-style portrait/silhouette illustrations
       keyed by entity id (for major figures) or role archetype
       (`metadata.roles`: *King, Prophet, Priest, Warrior, Shepherd,
       Apostle, Matriarch*).
8. **Door43 Russian open resources (`door43-ru`, CC BY-SA 4.0) & Open Study Bible integration**:
   `ru_tw` (**1,018** modern Russian Translation Words articles) and
   `ru_twl` provide Russian concept/name/realia articles, while `ru_tn`
   (Russian Translation Notes) + `AquiferOpenStudyNotes` (`aquifer-osn`)
   + `BiblicaStudyNotes` form the verse-by-verse commentary layer for the
   Open Study Bible atop `ru_rob.sbz` (modern Russian, 66 books,
   CC BY-SA 4.0), `russyn.sbz` (Synodal, PD), and `engbsb.sbz` (English,
   PD).
9. **Canon Writing-State Matrix ("Books Written Relative to Current Book")**:
   in book introductions and book overview cards, a compact visual grid
   of the canon (e.g. 13×3 for the 39 OT books, 9×3 for the 27 NT books)
   shows the state of the biblical library at the time the current book
   was completed. Each cell displays the localized short book code
   (`bookShort`) in one of four visual states:
   - **(1) Current book**: accent cinnabar/terracotta fill with white
     label;
   - **(2) Writing completed**: dark ink fill with white label
     (`written_end(K) <= written_start(current)` and certainty high);
   - **(3) Writing possibly completed / contemporary**: muted fill with a
     bold dark border (overlapping composition intervals or composite
     books spanning centuries such as *Psalms*, *Proverbs*, or *Job*);
   - **(4) Writing not yet completed**: muted flat fill without border
     (`written_start(K) > written_end(current)`).
   Driven by a compact `book_chronology(book, written_start,
   written_end, uncertain, events_start, events_end, author, place)`
   table in `knowledge.sb`, rendered natively in Flutter (theme- and
   language-aware, with tap-to-inspect tooltips, 0 KB raster overhead).
