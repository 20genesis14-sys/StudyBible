# Changelog

All notable changes after the 1.0 release — one per line.

## 1.0.2 (unreleased)

- [ ] TODO before release: replace the app icon with the final one
      (asset to be picked by the user).

- Fixed: the chapter grid briefly showed a fake "1" chapter while the
  module was still loading — now a spinner, an ellipsis in the counter
  and an indeterminate progress bar until the module doc arrives.
- Faster footnote/cross-reference cards: note texts are prefetched in
  the background when a chapter opens, references load in parallel,
  and card results are cached — cards open instantly on repeat taps.
- Speed: a module's SQLite connection is now opened once per session
  instead of re-reading the whole .sb file on every chapter request —
  noticeably faster footnotes, parallel passages, page turns and
  comparison on desktop and Android.
- Speed: texts of already-fetched verses are memoized per module —
  neighbouring notes referencing the same verse don't re-read it.
- Reading design: chapters open with a large inline chapter numeral
  (print-style drop cap); the heading splits into book name above and
  "Chapter N" beneath.
- New setting: text weight with four steps (Regular/Medium/Semibold/
  Bold) — in "Font and theme" and in Settings, with live preview.
- New "Licenses" page in Settings: deduplicated list of licenses used
  by the app with links to full texts, plus offline package-license
  texts via the built-in Flutter page. The SIL OFL text now ships
  with the bundled fonts.
- More reading fonts to evaluate: Lora, Alegreya, Source Serif 4,
  Roboto Serif, Charis SIL (full Cyrillic, variable weight) and
  Paper Mono (Latin only); the font picker is now a dropdown showing
  each name in its own typeface, variable fonts get precise `wght`.
- Fixed: "highlight color" now tints the verse text itself, not only
  the verse number (paragraph mode).
- Verse highlights are no longer only yellow: a six-color palette
  (yellow, green, blue, pink, purple, orange) — pick the color when
  highlighting from the selection menu or the verse popup; tapping a
  highlighted verse offers a new color or removal. Old entries keep
  working.
- Partial highlighting: any selected words, not only whole verses —
  userdata schema 4 stores a text selector `{exact,pre,post}` per
  record (matched by `frag::find_frag` in the core, survives module
  updates); overlapping ranges are refused, records of one gesture
  share a `created` batch stamp for future list grouping.
- Highlight polish: a tap on a highlighted fragment opens a
  no-dim pill (recolor/remove just that piece, a note on the phrase
  — it lives independently of the highlight); Strong's on long
  press; a "Highlights" section in Records folds one gesture into
  a line ("2 Цар. 2:2–4") and removes the whole batch at once.
  Known edge: interlinear word-pair columns don't paint partial
  highlights yet.
- Footnote card redesigned: height wraps content (max 75 % of the
  screen, long notes scroll), note text at a readable 15 pt base.

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
