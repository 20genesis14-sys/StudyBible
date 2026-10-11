# 0023. Cross-references as a shared layer module

**English** | [Русский](0023-xrefs-layer.ru.md)

Status: accepted (2026-10-10).

## Context

Cross-references (the OpenBible set, ~29.4 K links) used to be embedded
into each module at build time by `inject_xrefs`, duplicating the same
dataset into every translation: ~2 MB of `x` spans per module, a build
step per module, and the links baked into `content_hash`. A translation
without native parallels could only get them by rebuilding.

Conceptually, cross-references are not part of a translation's text —
they are a separate data layer, like a dictionary. The format already
has `meta.kind="layer"` (ADR 0016) for modules without their own text.

## Decision

1. **`openbible-xrefs` layer module** — a `.sb` with `kind="layer"`,
   `features="xrefs"`, no chapters/verses of its own. Links live as
   ordinary `x` spans: `(book_id, chapter, verse, seq, kind='x',
   caller='+', text)`, `block=0`. `text` stores language-neutral OSIS
   references (`Ps.104.30-Ps.104.31`); UI localizes labels via the
   book-name profile at display time.
2. **Reader merge** — when a module has no `x` spans of its own and the
   layer is enabled (setting `xrefLayer`, default on), `chapter_doc`
   injects the layer's links as `Note{x}` spans at the end of each
   verse. Modules that carry their own `x` spans keep them untouched —
   the layer only fills the gap.
3. **Bundled**: `openbible-xrefs.sbz` ships in `assets/modules` and is
   seeded to the data dir like the bundled Bibles; it is hidden from
   translation pickers (`kind="layer"`).
4. **Build**: `studybible module xrefs <cross_references.txt> --top N`
   produces the layer; `inject_xrefs` stays for modules that want links
   embedded (native parallels of a translation still belong inside it).
5. Module coordinates are `eng`; conversion to the target module's
   versification happens at read time via `Versification::convert`.

## Consequences

- Each shipped module drops ~2 MB of duplicate links; `russyn`/`KJV`
  rebuilds no longer need `inject_xrefs`.
- One dataset update refreshes every translation.
- Without the layer file a module simply shows no parallels — same as a
  module without `x` spans today. Links no longer enter `content_hash`
  (they are not part of the reading stream's text).
- The layer's OSIS labels (`Ps.104.30`) are re-rendered into the UI
  locale by the app; the stored form stays language-neutral.
