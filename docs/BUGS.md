# BUGS.md — log of fixed bugs and flaws

**English** | [Русский](BUGS.ru.md)

Format: date, symptom, cause/fix, commit. New entries on top.

## 2026-10-14

- **Reader mutated shared highlight/TTS cursors on `_ReadingScreenState`
  during build (Group 2)** — `_hlRaw`, `_ttsInVerse`, `_ttsWordCtx`,
  `_ttsRaw`, `_ttsLead` and `_ttsLeadDone` lived as mutable fields on
  the screen state, `_spansOf` lost the active verse across poetry block
  boundaries when a verse spanned multiple blocks without a repeated
  verse marker, and `_verseSpans` defaulted `hlWord` to `false` (muting
  per-word TTS highlight in verse-per-line mode). Fixed: moved the
  counters into a local `_SpanRenderCursor` passed through block/verse
  rendering and enabled `hlWord` for main-text lines.
- **Selection toolbar "Copy" copied raw spacing glyphs without a verse
  reference (Group 3)** — the stock copy action in `SelectionArea`
  copied em-spaces (`\u2003`), note dots (`\u00B7`) and inline verse
  numbers without book/chapter/verse or translation title. Fixed: the
  copy button in `_selectionMenu` strips service glyphs and formats a
  clean citation `«Text…» (Gen 1:1–3, Translation)`.
- **Group 1 bridge and `userdata.db` bottlenecks** — (1) opening a
  chapter or toggling a bookmark/highlight fetched all user records
  across all 66 books via four full-table `entriesList` calls; (2)
  every `userdata.db` bridge call opened a new SQLite connection and
  re-ran schema checks; (3) settings, reading position and navigation
  history shared `Kind::Mark` with user bookmarks; (4) `search_notes`
  ignored the external `openbible-xrefs` layer and returned verse `0`
  for heading notes; (5) native `module_doc`/`chapter_doc` serialized
  Rust structs to JSON strings only to `jsonDecode` them in Dart.
  Fixed: added `entries_for_chapter` (`entries_chapter`), cached
  `UserData` connections in `USERDATA`, moved settings/position to
  `meta` and history to `Kind::History` (`hist`) with automatic
  migration, extended `search_notes` to scan the active xref layer and
  return verse `1` for heading notes, and added typed FRB loaders
  `module_doc_typed` / `chapter_doc_typed`.
- **Mojibake in `kFullNameMod` (`lib/data.dart`)** — the 66 full Russian
  book titles for the `modern` name layout were double-encoded
  (UTF-8 bytes read as CP866 and saved back as UTF-8), showing garbled
  box-drawing characters on the Bible grid when both `bookFullNames`
  and `bookNames == 'modern'` were enabled. Restored to clean UTF-8.
- **`entry_add` re-unpacked `.sbz` on every chapter navigation and note/
  highlight save** — `api::userdata::resolve_module` called `open_any`
  instead of the shared `MODULES` cache (`open_cached`) and had no
  fast-path skip for service pseudo-modules (`""`, `"*"`, `"settings"`)
  or `hist*` history marks, so every `history.touch` unpacked the
  entire `.sbz` into memory just to read `meta`. Fixed: service/history
  records skip module resolution; real modules reuse `open_cached`.
- **`Settings.load` / `Settings._save` fetched the entire `mark` table
  and could race** — `bridgeEntriesList('mark')` was called without
  `module: 'settings'`, pulling all bookmarks and reading history into
  Dart on every setting change, and concurrent `_save()` calls could
  insert duplicate settings rows. Fixed: pass `module: 'settings'` and
  serialize `_save()` calls.
- **Desktop footnotes toolbar button only opened the side pane** —
  `_openNotes()` set `_notesOpen = true` on wide screens instead of
  toggling it. Fixed: `_notesOpen = !_notesOpen`.
- **Web cold start pulled ~28 MB — every bundled font** — the engine's
  glyph-fallback probe downloaded each of the 22 families declared in
  the manifest plus canvaskit/skwasm from the gstatic CDN. Measured
  with a headless-Edge CDP run (serve_web.py + script outside the
  repo): 28.5 → 12.8 MB after fixes. Fix: PaperMono/RobotoSerif/
  CharisSIL cut from the bundle (enum values kept as tombstones —
  the setting stores an index), the optional reading fonts (PTSerif,
  Lora, Alegreya, SourceSerif4) removed from the font manifest and
  loaded lazily via `FontLoader` (`ensureReadingFontLoaded`,
  `kLazyReadingFontAssets`), web built with
  `--no-web-resources-cdn` so skwasm is served locally.
- **The `assets/modules/` copy of `.sbz` in the web bundle** — the
  pubspec `assets:` entry duplicates `modules/` (~11 MB of extra
  deploy weight; not fetched at startup). Kept — native seeding needs
  it; noted so the web deploy can prune it.

## 2026-10-12

- **`Module::open_bytes`: buffer smaller than the data being copied for
  modules > 2 GiB** — the size was truncated to `i32::MAX` for
  `sqlite3_malloc` while `len` bytes were copied (out-of-bounds write).
  Now a size above the `i32`/limit is rejected with `BadFormat`; empty
  input gives a clear error instead of "out of memory".
- **`.sbz` without an unpack limit** — a "compression bomb" could exhaust
  memory. `sbz::unpack` is limited by `MAX_UNPACKED` = 1 GiB
  (`SbzError::TooLarge`).
- **Broken span slices and out-of-range numbers were read silently** —
  `start`/`len` outside the verse text produced empty text,
  `i64 as u16` truncated values. Now the slice is validated
  (`BadFormat`), numbers are read as `u16`/`u32` with a check.
- **Dictionary prefix: `%` and `_` acted as a LIKE pattern** — escaped.
- **Missing `book_headers` table** — the error named an SQL query; the
  table was added to the required list.

## 2026-10-06

- **Verse action menu at the bottom of the screen** — tapping a verse
  opened a panel at the bottom, far from the tap point; reading and
  paging was inconvenient. Replaced with a popup menu at the tap point
  (`_lastTapPos`, showMenu). `0704fcc`
- **The "°"/footnote-letter markers were nearly untappable on a phone** —
  the glyph was ~11 sp without a hit area. Added invisible ~28×28 dp
  padding (WidgetSpan + GestureDetector), glyph at 13 sp. `225343e`
- **Settings on desktop: black background, no "back", ESC dead** — the
  screen returned a bare ListView without a Scaffold. Wrapped in
  Scaffold + AppBar, ESC/back close the route. `f3ee75b`
- **Settings: controls overflowed the edge on narrow screens** — the
  language/font/layout segments overflowed a Row. The control became
  shrinkable with horizontal scroll, "narrow" threshold 480 dp.
  `82ecb75`
- **"Book · Chapter N" heading disappeared after a swipe** — it was drawn
  only on the temporary peek page. Now it stands at the start of every
  chapter in all layouts. `31f8bb0`
- **Top bar on mobile: the title was squeezed to "Genesi…"** — the search
  pill pushed it out. Search moved to a button in the bottom bar; the
  field floats above the panel. `b7e84f4`
- **planTodayIndex accepted broken dates** — `DateTime.tryParse`
  normalizes overflow ('2026-13-45' → January 2027). Strict `yyyy-mm-dd`
  check + roundtrip. `943c6d8`
- **Free notes did not survive a restart** — stored in memory only.
  Persisted as kind='note' records (userdata.db / localStorage).
  `08b486a`
- **Web: rough scrolling** — CanvasKit raster. Switched to
  `--wasm`/skwasm + COOP/COEP (multithreaded raster), JS fallback for old
  browsers, gzip in serve_web.py. `c470a49`, `ec122fe`
- **Quick navigation: long book list** — replaced by a colored grid
  (OT/NT/other), chapter cells compressed ~2×. `60a8bd1`, `3fb9c7e`,
  `f9b5bf4`
- **Search: redundant translation selection and book search in the Bible
  grid** — removed; search runs in the translation it was opened from.
  `65ad210`, `727f30a`

## Earlier (from ROADMAP)

- Note dialog crash on Android (`_dependents.isEmpty`) — own
  ScrollController and unfocus before closing.
- Web: sqlite3.wasm init race (`no such vfs`) — await init before the
  first read.
- Module map key race on catalog overflow.
