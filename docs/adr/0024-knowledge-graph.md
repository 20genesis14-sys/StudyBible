# 0024. Biblical knowledge graph — the `knowledge.sb` module

**English** | [Русский](0024-knowledge-graph.ru.md)

Status: design accepted (2026-10-12); implementation deferred — a
far-future track alongside format v2 and `studybible-text`.

## Context

The goal is quick access to entities related to the verse being read
(people, places, objects, customs, concepts, events): an entity card,
its relations, a list of mentions, articles and media — independent
of any particular translation and fully offline.

Format v1 already allows this without forks: optional tables and
`meta` keys are ignored by older readers (C-18), and text-less layer
modules already exist (ADR 0016 `kind="layer"`, ADR 0023 — the shared
cross-reference layer). The knowledge graph is the same kind of
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
   the graph updates independently of translations.
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
- Enriching existing `x`-spans with graph entities.

## Consequences

- Format v1 changes nothing structurally: a new `meta.kind` value and
  a fixed set of optional tables are added; older readers simply do
  not see the module.
- The graph is not duplicated per translation — one module for all,
  updated independently (like `openbible-xrefs`, ADR 0023).
- The effort concentrates in the data: `person`/`place` are covered
  by ready sources, while `concept`/`event` need authored content —
  the main risk and the reason for staging.
- Books in coordinates are addressed by `BookCode`, not local
  `book_id`: the module has no `books` of its own, so a numeric id
  would have nothing to resolve against. Compatibility of the code
  set with translation modules is checked by `module check`.
