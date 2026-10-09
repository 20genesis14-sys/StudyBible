# Changelog

All notable changes after the 1.0 release — one per line.

## 1.0.1 (2026-10-09)

- User records: schema 2 — a note/bookmark/highlight now carries the
  module's versification, module identity (content_hash) and a control
  fragment of the verse; old databases migrate automatically.
- Record relinking on module update: move by context to a neighbouring
  verse (±2), orphans reported; runs at app start, after module import
  and via `user relink`.
- Cross-translation records (stage A): a record has a canonical org
  coordinate; the note window has a "records in other translations"
  button; tapping a foreign record opens its verse in its translation;
  the "Records" tab shows all records grouped by translation.
- Fixed: a module resolves by `meta.id`, not by file name — a module
  imported under a foreign name received records without meta and canon
  and was invisible to cross-translation records and relinking.
- Import saves the file as `<meta.id>.<ext>` — re-importing the same
  module overwrites instead of producing copies.
- Fixed: relinking stamps the canonical range on records whose meta
  matches but canon is empty.
- Translation order in comparison: selected modules are reordered with
  arrows — in the comparison selection sheet and in settings.
- Export all records to Markdown: `studybible user export-md <file.md>` —
  grouped by translation and record kind (export only).
- "Records" screen: export/import buttons — an export menu to zip
  (transfer between devices, "newest wins" merge) and to Markdown
  (readable list, export only).
- "Records" screen: "Lost" section — records that lost their anchor on
  module update (relink orphans), with text and deletion.
- Desktop: Alt+←/→ and mouse side buttons X1/X2 walk the
  back/forward stack, like in a browser.
- The reader's external screens (Search, History, "Verse in all
  translations") open as workspace positions (kind='screen') without a
  new route: "back"/Alt+←/X1 return to the verse; jumping to a record
  from the foreign-records list is a stack step too, not a new screen.
- "Records" screen: a note's "share" button copies it to the clipboard
  as "Reference — text (translation)".
- Fixed (one of the sources): cross-references were bound to markers by
  order and a wrong anchor verse number — in verses with two or more
  markers, all after the first showed an empty card or foreign links.
  Now binding is direct by marker id.
