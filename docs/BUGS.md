# BUGS.md — log of fixed bugs and flaws

**English** | [Русский](BUGS.ru.md)

Format: date, symptom, cause/fix, commit. New entries on top.

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
