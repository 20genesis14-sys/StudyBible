# Changelog

All notable changes after the 1.0 release — one per line.

## 1.1.2 — Visual update (unreleased)

Usability and intuitiveness — fixing visual rough edges.

- Search: query operators `"phrase"` (exact phrase), `word*`
  (prefix), `?` (single letter), `*` inside a word — work across the
  Bible, module footnotes ("In footnotes" chip) and personal notes.
- Search: "By book" results mode — a List/By book segment,
  accordion "Name · N".
- Reading/Study mode switch as a glasses button, bottom-right corner.
- Contents (Bible book picker) as an open-book button, bottom-left
  corner.
- The header now shows the full book and chapter name, plus the
  translation and mode.
- Miscellaneous fixes.

## 1.1.1 (2026-10-12)

- Cross-reference layer stores structured targets (`xrefs_pack`):
  verse coordinates as packed data — the foundation for links that
  survive translation updates; display is unchanged for now.
- Layered cross-references now show book names in the interface
  language (was: English OSIS names from the layer itself).
- Web cold start is much lighter: the font manifest was cut to the
  fonts actually used (Paper Mono, Charis SIL and Roboto Serif
  removed), optional reading fonts load lazily only when selected,
  and skwasm/CanvasKit is served locally instead of a CDN —
  about 28.5 -> 12.8 MB on first load.
- Web/desktop: the footnote panel no longer sits under the top bar.
- Settings: switch rows are aligned evenly.
- Android: APKs are split per ABI (armv7 / arm64 / x86_64) with
  versionCode = version * 10 + ABI — smaller installs and the scheme
  F-Droid requires.
- Fixed: Android failed to load the Rust bridge library
  (libstudybible_flutter_bridge.so) in some builds.
- F-Droid recipe: reproducible build verified locally for all three
  ABIs (build + verify_apks + allowed signer).

## 1.1.0 (2026-10-11)

- New app icon — an open book with light on a dark-red background;
  an Android adaptive icon added (foreground + dark-red backdrop).
- Second bundled translation: King James Version (1769, eBible.org)
  with Strong's, cross-references and footnotes — seeded on first
  launch like the Synodal.
- Shared cross-reference layer `openbible-xrefs` (ADR 0023):
  translations without their own x spans get the OpenBible link set
  merged at read time; toggle in Settings; modules no longer embed a
  duplicate copy (russyn.sbz 2.78 -> 1.74 MB, kjv 8.2 -> 7.1 MB).
- Fixed web build: packed modules need the span_pack decoder that was
  missing on the web bridge (chapters showed no verse text).
- Module format: blob-packed `t` spans, tokens and alignment
  (ADR 0022, `meta.required="pack"`) — markup-heavy `.sb` modules get
  much smaller; old modules keep working, packed ones need the new app.
- Footnote/cross-reference cards now resolve verse texts in the
  translation being read by default (was: the main translation — a KJV
  reader saw Synodal texts); the xref translation setting stays, with
  a fallback to the main module when the chosen one lacks the book.
- Web reads `.sbz` directly: a vendored wasm zstd decoder
  (`web/zstd/`, @bokuweb/zstd-wasm, MIT) unpacks the same container as
  native platforms — one artifact per module, no `.sb`/`.sb.gz` pair;
  gzip/raw fallbacks kept for older deployments.

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
- Clearer chapter and verse numbering: chapters open with a large
  inline numeral (print-style drop cap) and a two-line heading —
  book name above, "Chapter N" beneath; verse numbers are accented
  (vermilion, w800) so anchors don't get lost in paragraph text; the
  drop cap doubles as the verse-1 anchor (tap selects the verse), so
  the duplicated "1" marker is gone.
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
- Highlights now come in six colors: yellow, green, blue, pink,
  purple, orange.
- Any selected words can be highlighted, not only whole verses.
- Tap a highlight for its menu: another color, a note on the
  phrase, removal. Strong's opens on long press. Records has a
  "Highlights" section: one gesture — one line, removed at once.
  Interlinear columns don't paint partial highlights yet.
- Footnote card redesigned: height wraps content (max 75 % of the
  screen, long notes scroll), note text at a readable 15 pt base.
- Reproducible release builds: Rust paths remapped to stable anchors
  (`/cargo`, `/src`), `.note.gnu.build-id` stripped from native
  libraries — two independent builds differ only in the embedded
  build path; the canonical F-Droid path makes APKs bit-identical.
- Voice accent dictionaries now ship as plain `.tsv` (was `.tsv.gz`) —
  transparent source data for repository scanners; `accent_init`
  takes TSV strings directly.
- `docs/MODULE-LICENSES.md`: per-module license and attribution
  statuses for all bundled `.sbz` modules.
- F-Droid store metadata: `fastlane/` directory with en-US and ru-RU
  descriptions, icon, feature graphic, screenshots and changelog.

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
- Reader AppBar "back" goes strictly up the hierarchy: chapter → the
  book's chapter grid. Reading-history back is the system gesture.
- Search shows a result count: "Found: N" under the query field;
  "Found: 100+" when truncated by the limit.
- Fixed (one of the sources): cross-references were bound to markers by
  order and a wrong anchor verse number — in verses with two or more
  markers, all after the first showed an empty card or foreign links.
  Now binding is direct by marker id.
