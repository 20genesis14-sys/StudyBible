# Accepted decisions

**English** | [Русский](DECISIONS.ru.md)

Edition 2. The source of truth for project decisions; brief rationale in
`adr/`, table of contents in `SPEC.md`.

## Goals
Two goals, both equal:
1. Reading: a simple, convenient, fast cross-platform Bible reading app.
2. Study: cross-references, Strong's lexicon, translation comparison,
   interlinears, originals, commentaries etc.
Order of work: reading first (Alpha 1), then study (Alpha 2). Goal 1 is
not more important than goal 2.

## Principles
User data (notes, highlights, bookmarks) is stored only on the user's
device. We store it nowhere else, there is no telemetry. Everything the
user loads themselves stays their responsibility.
The UI is replaceable: the core does not depend on it, the UI can be
rewritten.

## Measurable requirements (desktop, upper bound; faster is fine, slower is not)
Opening a chapter — no more than 50 ms. Searching the whole Bible — no
more than 200 ms. Cold start — no more than 1 s. Memory — no more than
150 MB with one translation open.
Minimum OS versions: Windows 10, macOS 12, Ubuntu 22.04, Android 8
(API 26), iOS 15. Windows 7/8 are not supported: since Rust 1.78 builds
for Windows only target 10 and newer.

## Platforms and technologies
Platforms: Windows, macOS, Linux, Android, iOS, web.
Order: desktop → Android, iOS → web at the very end.
No JS and no webview on desktop and mobile. On web a JS shell
(wasm-bindgen) is unavoidable, so the restriction does not apply there.
Core in Rust, ports-and-adapters architecture. Domain only in Rust.
The binding to the UI is single and thin, chosen together with the UI
(Slint — direct Rust call; Flutter — flutter_rust_bridge).
UniFFI and C ABI will appear only when they have a real consumer.
Platform status at 1.0 (2026-10-08): Windows/Android/web — release
artifacts built and run; **Linux — run and test-covered (release
GTK+Impeller, all limits met), no release build until there is
demand** — the recipe is `docs/BUILD-LINUX.md`, report
`docs/perf/linux-2026-10-08/`; macOS/iOS — after 1.0 (no Mac/Apple
account).
Module delivery (2026-10-08): exactly one base module is bundled —
`russyn.sbz` (3.3 MB, `assets/modules/`), seeded into the data
directory on first launch on all platforms; all other modules — user
import only. Translation pickers (Bible, settings, comparisons) show
**strictly installed** modules (`installedModules` — the scan result;
`kModules` remains a name reference). Windows data directory: was the
absolute `C:\StudyBible-data` → now `%USERPROFILE%\Documents\
StudyBible-data` (a visible place for import/backup); the
`STUDYBIBLE_DATA` override remains.
Web module bundle (2026-10-08): as on other platforms — only the base
`russyn` (`web/modules/russyn.sb` + index.json; `kBundledModules` =
['russyn']). Other modules on web are placed manually on the hosting
(file + an index.json entry) — there is no UI import on web (the
`import_module_stub` stub). Deviation from the "`.sbz` everywhere" rule:
on web the module is `.sb`: the web bridge reads sqlite via sqlite3.wasm
without the zstd path; compression for the network — `.sb.gz`
(DecompressionStream, optional).
Reader performance (2026-10-08): a chapter renders as a lazy list
(`ListView.builder` over lines/blocks) — before that the whole chapter
lived in one `Column` (~20k render objects on Ps 119 in study mode,
scroll and swipes jerked). Scrolling to a verse — by item index
(`_verseItemIndex` + `_seekVerseChapter`), not by GlobalKey. Derived
chapter views and second-line widgets are cached (settings signature).
Cost: "select all" covers only built items; auto-scroll during drag
selection works normally. Verified on a real phone — smooth.
Core ports: module storage, user database, index cache, speech;
later — repositories and network.
The file path is a desktop adapter; on Android — a content URI; on web —
OPFS (later).
Web foundation: no std::fs in the domain, the main thread is never
blocked.
Since Stage 0 the CI has one check: the core compiles for wasm32, without
running tests. Android and iOS builds and tests are added at Beta. The
web is finalized and tested at the very end.

## Interface
UI — **Flutter**, binding — flutter_rust_bridge (decision by the pilot
screen, ADR 0012 → ADR 0013). The Slint pilot screen is not built.
Pilot-screen checklist (UI acceptance criteria going forward):
- a chapter with paragraphs, poetry, a heading, a footnote and words of
  Jesus;
- mouse and keyboard selection;
- mixed Hebrew and Russian;
- word tap;
- a whole virtualized book;
- two panes with synchronized scrolling;
- screen-reader operation;
- OS font scale.
Synchronized scrolling: an "anchor ↔ pixels" correspondence and a
leading-pane rule.
Fonts for Hebrew with cantillation and polytonic Greek — bundled, under
OFL.
UI languages: Russian and English immediately, others via localization
files.

### Design system and navigation (from the prototype, ADR 0013)
- The 66-book grid is continuous, two blocks (Hebrew Scriptures /
  Christian Greek Scriptures); book groups — by tile color only (10
  groups, contrast ≥ 4.5:1). Chapters — a grid; a read checkmark, a book
  progress bar, a "continue" marker.
- Chapter: swipe and ← → keys across book boundaries; verse numbers in
  the group color and bold; tap a verse → action panel + a footnote side
  panel (mobile — a sheet); double-tap → translation comparison.
- Layout modes: paragraphs (indent) / "verse per line"; font scale via
  slider and Ctrl+wheel; a narrow "Reading" column option.
- Themes: light "paper" — the ADR 0015 palette (warm sepia, ink,
  vermilion accent), dark "for the eyes", AMOLED (in dark themes
  vermilion is given as a lightened shade).
  Reading fonts: bundled Literata and Gentium Book Plus, system — an
  option.
- Verse picker — a toggle in settings; bottom menu: Home / Bible /
  Reading schedule / Modules / Settings (the "Dictionaries" tab was
  renamed to "Modules" — it manages text modules and dictionaries).
- "Reading schedule" — a progress screen: an overall read-chapters
  counter and bars by section (OT/NT) and by book; a "Notes" block on
  the same page.
- Reading-screen panels: "liquid glass" — blur σ2 + card fill 0.3 + a
  light rim highlight to the content (apple-style); text under the
  panel reads through. Before: σ8 + 0.5 looked like a solid fill.
  Top bar: the search field always fully on screen, the book title is
  trimmed to ~12 chars with an ellipsis — long names do not push out
  search.
  Bottom bar on a narrow screen — no chapter arrows (pages are swiped);
  actions — large icons with color accents. Note dialog: actions as
  icons (three text buttons in a column overlapped the fields under the
  keyboard).
  Read-aloud: a mini-player above the bottom bar (verse ‹/›, pause,
  stop, place, a progress slider over the chapter's verses — draggable)
  and an Android media session (audio_service — notification, shade,
  audio focus). Reading continues in the background (mediaPlayback
  foreground service, WAKE_LOCK); swiping the app away from "recents"
  (onTaskRemoved) ends the reading session.
- Dialog controller lifecycle: a TextEditingController must live in the
  dialog's State (dispose in State.dispose). Owning it outside
  showDialog (create → await → dispose right after return) caused the
  assert '_dependents.isEmpty' / 'child.owner == owner': dependent
  InputDecorator elements stay active when dispose touches the list in
  the middle of route teardown. Same rule — actions from the selection
  context menu run at end of frame after hideToolbar.
- Scrolling to a verse on a jump (verse picker, verse of the day,
  footnotes): the verse anchor is a zero-width WidgetSpan on the verse
  number inside the text (the exact verse spot, not the paragraph
  start); for a verse without a live anchor, scrolling takes the nearest
  attached verse before the target (_ctxForVerse). In the "Book" feed
  chapters build lazily — the iterative _seekVerseBook: each iteration
  forces a frame (scheduleFrameCallback + addPostFrameCallback — on a
  static screen endOfFrame never comes, and a jumpTo without a frame
  moves the position only "on paper"); an anchor outside the 10–60 %
  viewport comfort zone — a direct jumpTo to 15 % (ensureVisible at ~2
  fps does not progress); no anchor — a jump to the ribbon-fraction
  estimate ext·(ch-1)/total for a far chapter or a viewport step for a
  neighbor (the index estimate systematically overshoots on uneven
  chapters); exit on two stable frames in a row or a repeated estimate.
  "Stale" keys of chapters thrown out of the viewport do not count as
  built (currentContext == null → skip).
- Chapter paging — page-based, as in readers: a horizontal drag pulls
  the current page with the finger while the incoming chapter slides in
  next to it (both with text: the target is loaded by ensureChapter at
  drag start; the peek page has no anchors or shared keys — a duplicate
  GlobalKey). A held finger keeps the page in place; release — completes
  the transition past 25 % width or on a ~400 px/s fling, otherwise
  rolls back (Curves.easeOutCubic, ~190 ms). In "book" mode a page is a
  transition to the adjacent book. The transition target is _goTarget,
  shared with _go without side effects. Structure: Listener (not
  GestureDetector — that would break text selection) with pointer-move
  tracking.
- Footnotes: Bible references in the text ("Gen 1:1", "Gen 2:19") are
  hyperlinks; a jump opens the chapter and scrolls to the verse, the
  translation is preserved.
- Settings persist: saved as JSON into userdata as a record kind=mark,
  module='settings', book='SET' (a legal anchor without a text binding).
  Settings.load() at start; Settings.update() saves after load
  completes (_loaded — so defaults do not overwrite saved values).
- Main translation: settings.defaultModule, default 'russyn'; the
  helper mainModuleId() in data.dart — falls back to the first
  available module if the setting's id is absent on the platform.
  Selection in "Settings" (persisted, applies at launch) and via the
  "Translation" chip in the top bar of the "Bible" tab (a module-list
  sheet, the choice immediately changes the book grid's loaded module).
  All jumps without an explicit moduleId (chapter grid, search,
  reading) use mainModuleId().
- History is unified across modules: kind=mark records with the 'hist'
  text prefix — 'hist' (chapter: module+book+chapter+verse),
  'hist:dict' (dictionary entry: context 'H3117|word'), 'hist:search'
  (query: context=query). Written on chapter open, translation change,
  search, dictionary-entry expansion and Strong's-card opening. The
  "History" screen shows a feed of all types with the module name; a
  tap restores the context (chapter+verse in that translation,
  dictionary → the card, search → the screen with the same query).
- Dictionary: Strong's Exhaustive Concordance (Hebrew + Greek) from
  openscriptures/strongs, XML under CC-BY-SA — the Strong's text of
  1890–94 is in the public domain; Open Scriptures attribution is shown
  in the "Modules" section. Stored as compact JSON (14 298 entries) in
  assets/data/strongs.json. Search by number/lemma/definition; tapping a
  word with a Strong's number in the module text opens the entry card.
- Russian Strong's dictionary: the Yu. A. Tsygankov edition ("Библия для
  всех", SPb., 2005) — 8 674 Hebrew + 5 523 Greek entries; data source —
  azbyka.ru (via the ChurchPresenter repository). It is a copyrighted
  translation: as user data it lives in STUDYBIBLE_DATA/dictionaries/
  strongs_ru.json (generator tools/gen_strongs_ru.py), NOT in the
  repository and NOT in the public build. With the file present, Russian
  definitions overlay the English dictionary (lemma, transliteration,
  pronunciation — from the Russian entry; derivation, points and KJV —
  from the English one); without the file the English one works. The
  local web build reads the same file from dicts/strongs_ru.json.
- Web module serving: we deploy `modules/*.sb.gz` (gzip -9, ~60 %
  lighter — 313→123 MB) plus an index.json with the list;
  `native_bridge_web` on module open first downloads `<path>.gz` and
  decompresses with the browser's DecompressionStream, on 404 — the raw
  .sb (local development does not break). Reason: transferring a large
  catalog to the hosting flakes out.
- Non-canonical module books: the book grid shows module books outside
  the 66-book catalog in a separate "NON-CANONICAL BOOKS" section (the
  BookGroup.other group, gray); book-to-book navigation on the reading
  screen follows the module's book order (the module's `books`, not
  kCatalog). Tests are deliberately not written (user instruction) —
  the behavior is documented here; the check will be on the real LXX
  module.
- Interlinear modules (word-over-word): each "translation/original"
  pair — a text span style='w', the text is the gloss, the original
  word — in the attrs attribute `gr="…"`. Meta flag: `interlinear='1'`.
  The reading screen draws such chapters as "gloss over original"
  columns (original font by the span's language; for gr= —
  GentiumBookPlus) in all layout modes; the same renderer in inline
  comparison. The int-en source format: "gloss / greek / pairs" blocks
  — the converter scripts/build-interlinear.py. The int_en module
  itself (Kingdom Interlinear) is the user's personal module: not in
  the repository or builds, installed via "Import .sb".

### Visual language and UI model (2026-10-05, ADR 0014, 0015)
- The UI is described by data: Workspace → Pane → Layer (JSON in
  userdata). The reading screen is split into `reader_controller.dart`,
  `chapter_renderer.dart`, `reader_pane.dart`, `reader_chrome.dart`,
  `page_swipe.dart`, `tts_service.dart`, `notes_sheet.dart`,
  `reader_dialogs.dart`. At the first step these are `part` extensions
  of the screen state; look and behavior unchanged. Layout editor —
  after 1.0, the model — now (ADR 0014).
- Unified workspace logic (2026-10-12, user decision, ADR 0019): when
  comparing two or more translations the internal logic is **not
  duplicated across panes** — it is one per workspace. Ownership
  levels: TTS, the history journal and the module cache — at the
  **app**; the jump stack and pane list — at the **workspace**
  (`ReaderWorkspace`, data outside the widget tree); a pane is only a
  view of a position. Single TTS: however many panes are open, one
  position is voiced; the voicing source is bound to the position, not
  the pane widget (switching to an additional pane — later,
  architecturally provided). The reader is unique: "to the place"
  jumps from anywhere — a `push` of a position into its stack, no new
  reading-screen instances; a second workspace — only for a second OS
  window (a separate later decision).
- Position stack (2026-10-12, ADR 0019): short memory up to 250 jumps,
  **persistent between launches** — start returns to the closing place
  and "back" steps through the past session; the full journal is
  unbounded, jumps from it are manual. Position = `(kind, ref)` with an
  extensible `kind` + a full pane snapshot (module, layers, mode).
  Written to the stack: swipes across a chapter, jumps, translation
  change on the spot; scrolling inside a chapter and repeating the same
  position are not written. "Back" returns to any place (translation,
  dictionary, apparatus); scroll restoration — to the verse; sheets and
  cards close before the stack step; TTS stops on a step. No
  back/forward buttons in the reader bar — the "More" item opens a
  compact pane with ‹ › stack steps; expanding it leads to the
  "History" screen; keys/mouse buttons — later. Start — on Home (the
  closing place via "continue reading", the past session's stack
  restored in the background); on an empty stack "back" goes to Home.
  Implementation (2026-10-12): `ReaderWorkspace` in
  `lib/workspace/reader_workspace.dart` (the same global-services
  layer as `state.dart`); the stack persists as one UserData record
  (`kind=mark`, `module='settings'`, `book='WS'`, context — JSON
  `{index, stack}`); a record's pane snapshot — an open dictionary
  `pane`, currently keys `interleaved`, `cmp`, `cmps`; `PopScope`
  intercepts system "back" (the search field closes first, then a stack
  step, then pop); compact ‹ › — a row in the "More" sheet with the
  stack depth.
- Contribution registry and extension engine (2026-10-12, ADR 0020):
  `ContributionRegistry` — a single point for layers/panes/actions/
  presets; our features are registered with the same descriptors future
  plugins will get (hardening the API on ourselves). Unknown `typeId` —
  a soft skip. Extension engines — the `data | ui | web` ladder: the
  declarative DSL is the main path (we render: no WebView seam, no iOS
  risk), `web` is a fallback hatch; no general-purpose computation —
  the author precomputes as data in `.sbz`. Manifest: `id` (eternal),
  `api`, `engine`, `contributes`, `activationEvents`, `permissions`.
  API = events + transformers + capability handshake.
  `ReaderWorkspace` implementation — a global `ChangeNotifier` in
  `state.dart`; Provider/get_it postponed. Order in 1.0: registry →
  back-stack → 3+ comparison → auto night mode.
- Panes (2026-10-12, ADR 0019): the main one alone has full logic;
  additional ones are synchronized by default (including versification
  conversion), support "light detach" to any position; a link jump
  inside a detached pane stays in it and is not written to the stack.
  Return to sync — the logic is ready, the button — after release. Pane
  count — a formula from width/scale, manual adjustment later.
- Visual language "book and vermilion": warm paper, ink, one red
  accent; a chapter-number initial, superscript verse numbers
  (ADR 0015).
- "Reading" (clean text) and "Study" (verse per line, margin dot,
  footnote letters) modes — one toggle in the top bar.
- The "Layers" sheet instead of separate comparison/interlinear/
  footnote buttons.
- Bottom reading bar: Translation · Layers · Listen · More
  (monochrome, background gradient instead of blur).
- Bottom navigation — variant A: Home · Bible · Plan · Records ·
  Library. Search — a field at the top of Home and a "Search" button in
  the reading bottom bar (a floating field above the bar); on Bible
  there is no search field — a book grid without a filter. Settings — a
  gear on Home. On Home — a "Today by plan" card.
  Alternative B (Today · Bible · Search · Records · Library, plan as a
  card on Home) is recorded in ADR 0015 for a possible return.
- The "Plan" screen (formerly "Schedule"): the active plan with a
  progress ring and day streak, a week strip, a "Today" list with
  checkmarks, a "Read map" (a column = a book, width = chapter count,
  color = group), other plans.
- Reading plans in the first version (2026-10-05): "Chronological"
  (the whole Bible in event order) and "Gospels" (Mt, Mk, Lk, Jn — 89
  chapters). The user will add other plans later. A plan is data (JSON:
  day → list of chapters or ranges), not code: a new plan is added by a
  file (assets/data/plans.json). The chronological-order source is the
  user's annual schedule sbr_U.pdf (question № 38 closed): OCR by
  columns, 66-book coverage verified by a test. Plan choice and start
  date — in settings; a day is done when all its chapters are marked
  read.
- Book grid: the layout and saturated tiles per ADR 0013 stay. Group
  color saturation lowered by 15–20 % (white-text contrast ≥ 4.5:1
  preserved). Full book name under the abbreviation — a settings
  option, ≥ 11 sp. Tonal tiles (mockup 3) rejected.
- Reading typography (goal before Beta / in Beta): default size
  20–21 sp; variable Literata with the `opsz` axis; left-aligned by
  default, justified only with hyphenation; PT Serif (OFL) in the font
  list.
- Footnotes: by default a superscript letter at the word, no space,
  non-breaking (variant A); a dotted underline on the word with no sign
  (variant B) — if the module has anchor text. In "Reading" the marks
  are hidden; tap → a card; the marker hit area ~28×28 dp (invisible
  padding; 44 dp inside the line would break the line spacing).
  The card is tall (~75 % of the screen): references stay hyperlinks,
  under each — the text of the verse(s); the text translation is
  configurable ("Cross-reference translation", the main one by
  default). Footnote and parallel text size — separate sliders
  (footScale/xrefScale) in the "Font and theme" sheet and in
  "Settings".
- A tap on a verse/verse number — a popup menu at the tap point (not a
  bottom panel): Copy, Highlight, Note, Tags, Bookmark, Compare,
  Parallels (if any), Share.
- "Compare" — a separate "the verse in all translations" screen: a card
  per translation with the verse text, a tap → jumps to the verse in
  that translation; the translation list — checkboxes in settings (all
  by default).
- Translation comparison (2026-10-12): column mode (`_compare`, second
  column/pane) is **temporarily disabled and hidden in the UI** until
  the first version after release — the implementation is raw; the code
  is kept, only entry points removed (top-bar button, "Layers" toggle,
  double-tap). Next, two forms per the user's decision: (a) inline
  comparison extends to a module list — a `compare` layer with
  `modules: [...]`; (b) multi-column comparison — not a separate mode
  but synchronized additional panes (ADR 0019). Implementation of (a):
  the list — `settings.interleavedModules` (CSV in display order; an
  empty value — the former single second translation); versification
  conversion cached per module; with 2+ lines — a translation-name
  label; selection — chips + a checklist in "Layers", removing the last
  translation turns the layer off; module reordering — after release.
- Auto night mode by time (2026-10-12, implemented):
  `settings.autoNight` + `nightStart`/`nightEnd` (minutes of day, an
  interval across midnight supported) + `nightTheme` (Dark/AMOLED);
  MaterialApp builds from `settings.effectiveTheme`, the day-theme
  choice is stored separately; recompute — a lazy timer once a minute,
  lives only while the mode is on, an event fires only on a theme
  change; UI — in "Settings" under the theme picker.
- Notes: separate title and text (stored as "title\x1Ftext" in the
  record's text field); editing and deletion in "Records"; a verse note
  navigates to its place on tap.
- "Font and theme" in the "More" menu — a local sheet (theme, font,
  text and footnote sizes), without going to "Settings".
- Text search — without picking a translation: it searches the
  translation the search was opened from (from reading — the current
  one, otherwise the main one).
- Web: a `--wasm` build (skwasm renderer); multithreaded raster via
  COOP/COEP (serve_web.py → crossOriginIsolated, SharedArrayBuffer);
  JS+CanvasKit fallback for old browsers (flutter_bootstrap.js chooses
  itself); serve_web.py serves gzip.
- Cross-references — per verse parts: the sign's position and the
  anchor text are preserved at conversion; the sheet groups references
  by parts (`1:1a`); no anchor — a reference to the whole verse.
- Design-review mockups — local, not in the repository.
- Theme and font engine (after 1.0): user themes — a palette editor
  (background/cards/text/accent/edges) on a light or dark base, named
  themes, file export/import; user fonts — adding TTF/OTF to the
  reading font list.
- Reading statistics (after 1.0): built-in local telemetry — average
  chapters/verses per day, time in the app by days and weeks, a
  calendar breakdown (a separate button screen), most-read books and
  chapters. Locally in userdata.db only, no network. Display —
  infographics on the "Plan" screen.

## Licenses (minimum)
Code: MIT OR Apache-2.0, copyright holder "StudyBible contributors".
Closed modules and plugins are allowed.
cargo-deny in CI checks dependency licenses.
Texts are separate from the engine. A module's metadata carries a
license and attribution, the app shows them. We do not perform a
detailed legal review.

## Data and modules
A module is our own SQLite format: text, markup, tokens, metadata.
The FTS index is not part of the module. It lives in a local cache,
built by the app or the converter.
The cache key is the module content hash plus the tokenizer version.
A module is an untrusted file: read-only, SQLITE_DBCONFIG_DEFENSIVE,
trusted_schema=OFF, a schema and format-version check.
User data — a separate database with a schema version and migrations.
Module metadata: id, version, language (BCP 47), writing direction,
versification, canon profile, book-name profile, license and
attribution, rights flags (copying, network, AI, plugins — groundwork
for the future).
Encoding: UTF-8. Translations are stored in NFC. Originals are stored as
in the source: for Hebrew NFC reorders vowel marks, so normalization
applies only to search keys.

Coordinates:
- verse — (versification, OSIS book, chapter, verse, optional segment);
- original word — a stable token id in a named edition;
- alignment — many-to-many links, unpaired words allowed;
- position in a translation — verse + character offset + a text check
  fragment;
- non-verse content (introduction, article, a commentary on a range) —
  an element id.
A user record stores the module id and version, the pointer type and
always a verse coordinate as a fallback. In the v1 schema the module
version and versification are not there yet (open question № 12).
On module update: a map from old ids to new ones; without it —
re-anchoring by the check fragment; failing that — fallback to the
verse.

Versifications are data: Paratext under MIT (org, eng, lxx, vul, rso,
rsc) plus a cross-check against TVTMS. Imported with reference tests.
Mappings account for 1→N, N→1, verse parts and "no correspondence".
A distorted mapping row must not break the file: the parser skips it
and records it in `skipped()`. Three distorted rows were found and
fixed locally in vul.vrs (question № 10 — upstream libpalaso matches
byte-for-byte, the same typos there): `DAG 3:52-23` → `DAG 3:52-53 =
S3Y 1:30-31`, `DAG 13:1-63 = SUS 1:63` → `SUS 1:1-63`, `DAG 14:1-42 =
BEL 1:42` → `BEL 1:1-42`; the original form is recorded as a comment in
the file.
Unequal ranges: verses are matched in order, the long side's excess is
attached to the short side's last verse (question № 8 closed — our rule
on the checked pairs Ps 89/90 and Ps 141/142 is more accurate than
Paratext's behavior, which overwrites the correspondence with the last
row).
Translation comparison in the app goes through the core's
versification (questions № 8–9): the verse number is translated
between module versifications in inline and column comparison, on the
"Compare" screen and in footnote/parallel cards. If several
second-translation verses correspond — all their lines are printed in
a row with their numbers. A superscription (verse 0) is shown as a
separate line above the first verse in both comparison parts
(variant A); in a translation where the superscription is part of verse
1, the line is empty.
A lettered verse segment (`1:1a`) is discarded at parsing — open
question № 13.
A module's versification tag is the file's own numbering. russyn is
`rsc`. eBible engwebp and eng-kjv2006 are `eng` (Mal 4, Joel 2:28–32),
not `org`: tagged `org`, those verses would not open by link (fix of
2026-10-02).
The Paratext/USFM ↔ OSIS code mapping is an explicit data table.
Books outside org (Ps 151 etc.) get a coordinate in their own
versification.
For MyBible and BibleQuote the versification at import is determined by
a heuristic with confirmation.

## Canon, book names and order
The main canon — 66 books per the submitted list (the file
canon-66-knig.md). Everything else is marked non-canonical. Marked:
- whole books: Tobit, Judith, Wisdom of Solomon, Sirach, Baruch, Letter
  of Jeremiah, 1–3 Maccabees, 2–3 Esdras, Prayer of Manasseh;
- insertions inside canonical books: additions to Esther, Dan 3:24–90,
  Dan 13–14, Ps 151, verses added from the Septuagint (Josh 24:34–36,
  Prov 4:28–29, Prov 13:14).
The non-canonical is shown with a mark by default. It can be hidden in
settings.
Data profiles: canon (the book set and marks), names and abbreviations
(Synodal, English), book order (as listed, Synodal, English).
Names, abbreviations and order are set by the module by default.
The Synodal-to-OSIS book-code mapping:
- 1–4 Kingdoms = 1Sam, 2Sam, 1Kgs, 2Kgs;
- 1–2 Chronicles (Паралипоменон) = 1Chr, 2Chr;
- 1 Esdras = Ezra;
- 2 Esdras = 1Esd, 3 Esdras = 2Esd (consistent with the rso chapter
  counts: 1ES — 9, 2ES — 16).

Profile data: `data/profiles/books.tsv` (78 books: OSIS and USFM codes,
canon, list and Synodal order, Synodal and English names and
abbreviations) and `data/profiles/noncanonical.tsv` (non-canonical
books and insertions in rso coordinates). The source is
`data/canon/canon-66-knig.md`.
Versification files — `data/versification/*.vrs` (libpalaso, MIT,
commit f1f70e9). Found at cross-check: eBible russyn follows rsc but
contains Septuagint insertions in rso numbering — Josh 24:34–36,
Prov 4:28–29, Prov 13:14; they are marked non-canonical.
The Esther additions in rso — a separate book ESG with segments
(ESG 1:1a…).
The reference parser knows the versification and the name profile.
Ambiguous abbreviations resolve through the active profile.
"Ps 22" in Synodal versification is Ps 23 in org.

## Module format v1
- Reading stream: a chapter is a sequence of blocks (paragraph, poetry
  with levels, section heading) and inline spans (verse marker, added
  words, words of Jesus, God's name, footnote callout, reference). The
  listed USFM subset survives a round-trip conversion.
- Footnotes, cross-references.
- Section headings — a separate layer.
- Original tokens: lemma, morphology, Strong's, kethiv/qere.
- Alignment.
- Dictionaries with multiple keys (Strong's, lemma, word).
- Commentaries on a verse and on a range.
- Supplements: introductions, glossary, tables, captioned images
  (maps as images).
- A common mechanism of optional versioned layers.
- A "requires unlocking" flag — groundwork for the future.
Rights flags decided (question № 15 closed): the optional
`meta.rights` key = a comma-separated prohibition list —
`no-distribute`, `no-net`, `no-ai`, `no-plugins`. No key — everything
allowed; an agreement, not DRM.
Optional extensions before the freeze (ADR 0016, 2026-10-05/06):
`meta.kind`, `meta.features`, `meta.rights`, the `tokens`, `alignment`,
`variants`/`readings`/`witnesses` tables, `entries` (`kind=dictionary`
modules, input — TSV `headword → text`), binding footnotes and
cross-references to a verse part, the `.sbz` transfer container (zstd +
brotli, a codec byte for the future). Builds produce `.sbz` by default
(2026-10-11): `"sbz": false` in modules.json keeps `.sb` — for web
serving.
Condition: converting foreign modules and authoring our own stay
simple — the converter fills the tables itself, the author writes
USFM/OSIS and simple TSV, no SQL. Extensions do not go into `required`.
Two more options added (2026-10-06): `fts` — a built-in FTS5 index
inside `.sb` (`"fts": true` in modules.json; without it the reader
builds the `.idx` cache as before — question № 23 closed); `marks` —
time marks for audio sync/per-word TTS highlighting (input — TSV).
Clarification (2026-10-12): `fts` is a conversion option, **not a
default for any platform**: a built-in index inflates the file (russyn
13.2→24.1 MB), unacceptable for web. Web modules ship without `fts`;
the web bridge builds FTS5 itself in the in-memory database in the
background after opening the module (batches of 500 verses,
`meta.norm_version` — after full insertion; until ready, search runs a
LIKE scan). The index lives one session — cross-session caching via
IndexedDB is postponed (OPEN-QUESTIONS). Desktop modules with `fts`
(flag/`module index`) are read as before; without `fts` — `.idx`
cache/LIKE.
Reading `.sbz` (2026-10-11): the app and CLI open a compressed module
via `sqlite3_deserialize` — the whole database in memory, read-only,
no unpacked copy on disk (old `*.unpacked.sb` caches are cleaned).
`.sb` is read as a file as before.
Compact module schema (2026-10-12, ADR 0016 item 15 — the last change
of existing fields before the v1 freeze): books are addressed by
`book_id INTEGER`, not a text code; verse text is stored once — the
canonical raw buffer in `verses.text`, text spans carry a byte slice
`(verse,start,len)`; `kind='v'` remains only on empty verses and
markers in headings, other boundaries are synthesized by the reader
from the `verse` change. We do not move `x` into a separate table:
targets are stored as a ready string, sources have no structural
coordinates — no gain (the item is in ADR 0018). Old `.sb` do not
open — modules are rebuilt by the converter.
Module format v2 (a custom packed format with its own index, HTTP
Range streaming, a single Rust reader) — postponed until after the 1.0
release, no deadline: rationale and sketch — ADR 0018.
Extensibility: the architecture keeps a "document tree" abstraction
(book→chapter→verse as section→subsection→unit) so the reader can be
specialized beyond the Bible — recorded in ADR 0018.
The 1.0 freeze means a ban on changing or removing existing fields.
New — only optional tables. The module stores the format version and a
list of mandatory capabilities.
Format semantics (2026-10-12, the "Semantics" section in spec/05):
- Reader policy — soft: structural errors → refusal; semantic
  anomalies (superfluous `v`, `features` without data, unknown `kind`)
  → the module is read, `module check` shows warnings.
- `meta.features` — an open list; `x-` is the experimental prefix.
- `meta.content_hash` — the exact algorithm is fixed in the spec
  (rule C-12): deterministic stream serialization → SHA-256.
- `for_search` (rule C-13) — part of the format: `entries.norm` and
  `fts.norm` are built by the same rules (`norm_version="2"`).
Additional decisions (2026-10-12):
- The vocabularies of `blocks.marker`, `spans.style`, `spans.attrs`
  keys — open, like `features` (C-6): unknowns are softly ignored.
- Verse numbers in a chapter do not decrease for `bible`/`interlinear`
  (C-4); a verse repeat is legal in commentaries. `num` is defined only
  on `v`.
- `chapter=0` — a book introduction (C-19).
- Optional tables are legal with any `kind` (C-20): a Bible may carry a
  built-in `entries` lexicon.
Format mode (2026-10-12): **pre-freeze** — schema and semantics are
final, the formal freeze is postponed until real-user feedback. Format
v2 (ADR 0018) is a separate artifact: it may change anything (a
different `format_version`, its own storage); the v1 freeze does not
bind it. v1 support in app ≥1.5/2.0 — a separate decision (keep or
drop); a v1→v2 migrator is trivial since the v1 semantics are
documented (C-1…C-20).

## Converter
A library (crate) plus a shell; used as a library on mobile. No GPL in
our code.
SWORD — through an optional external program that dumps OSIS.
Order: OSIS, USFM → Zefania → MyBible, BibleQuote → SWORD → MySword,
e-Sword.
Building modules from USFM: `studybible module build` reads
`data/modules.json` (metadata and source id) and writes `*.sb` to
`<data root>\modules` (wrapper — `scripts/build-modules.ps1`). An
existing file is not replaced: writing recreates the schema and stops;
the old `*.sb` must be removed by hand.
The book USFM files are taken by name in sort order; eBible file
numbering gives canonical order (FRT first, GLO last).
USFM-parse limits of v1: merged verses (`\v 1-2`) take the first
number; nested styles keep only the inner one (`\wj \w…` → `w`); in
footnotes and references the `fr`, `xo`, `fv` labels are discarded —
the link target's text is not preserved yet.
The MyBible (`format="mybible"`: a Bible from `*.SQLite3`, commentaries
from `*.commentaries.SQLite3`, a dictionary from `*.dictionary.SQLite3`)
and BibleQuote (`format="biblequote"`: a directory or zip with
`bibleqt.ini`, UTF-8 or cp1251 encoding) converters are built into
`studybible-convert` (2026-10-07, ADR 0016 item 14).

## Search
The FTS5 index in the cache — `studybible_store::SearchIndex`, a
`<module>.idx` file next to the module (or the `--cache` flag). The
cache key — the module `content_hash` + tokenizer version (`1`); when
normalization changes the version rises and the cache rebuilds. The
`fts` table stores normalized text (`core::normalize::for_search`:
case, ё=е, pre-reform letters, diacritics via NFD), verse coordinates
as unindexed columns.
Query: words are normalized and joined with AND, order by bm25.
Done in the MVP: exact form (`for_search`) and AND. Stemming,
lemmatization, phrase, NEAR, word-start, scope restriction and
multi-module search — not yet.
Normalization levels (target; `for_search` currently does only what is
stated below):
- Russian — case; ё = е; stress marks and soft hyphens; pre-reform
  ѣ, і, ѳ, ѵ; "й" is kept separately ("мой" ≠ "мои") — NFD decomposes
  it into "и"+breve, so we hide it behind a private-use character until
  decomposition;
- Hebrew — te'amim and vowel points removed (NFD). Final letters and
  maqqef not yet (open question № 14);
- Greek — case, accents and breathings, iota subscript (via NFD).
  Final sigma is not folded to regular (question № 14).
Further as planned. Translations: exact form already there; stemming
(Snowball for Russian and English) and lemmatization (OpenCorpora
dictionary) — later.
Originals: search by lemma, Strong's and morphology from data, no
stemming.
Phrase, NEAR, word-start, scope restriction (books, canon, range).
Multi-module search: results grouped by module, bm25 of different
indexes is not mixed.

## Output
Several translations in columns or lines, alignment through
versification maps.
Screen layouts — data.
Copying a verse: text, reference, short translation name, attribution.

## Voice and accessibility
(a) Screen readers: NVDA, JAWS, Narrator, VoiceOver, TalkBack, Orca.
This is a requirement for the very first text widget (Alpha 1) and a UI
selection criterion.
- Every verse is an accessibility node with number and language.
- Keyboard navigation by verse, chapter, book.
- Footnotes and references reachable from the keyboard.
- Announcements like "Genesis, chapter 3".
- OS font scale, high contrast.
- Check — a checklist on each reader.
Risk: AccessKit (what Slint depends on) has no rich text and hypertext
yet. This is checked on the pilot screen.

(b) Read-aloud — Russian and English only. Ancient languages are not
voiced.
The "Speech" port in full: a fragment with a language; pause, resume,
stop; speed and voice; fragment start/end events.
In the MVP console `say` (interrupting the current), `speaking` and
`stop` are done.
`speakable()` prepares the text: verses without footnotes, references
and headings.
Pauses, speeds, voices, fragment events, numbers and references as
words, stress marks and skipping Hebrew/Greek as a separate layer are
not there yet.
System-synthesizer adapters via the tts crate (MIT): WinRT/SAPI 5,
AVSpeechSynthesizer, Android TextToSpeech, Speech Dispatcher, later
Web Speech API.
Third-party voices connect through the OS (RHVoice, SAPI 5 voices,
Android engines).
The core prepares the text:
- what to read (numbers, headings, footnotes — by settings);
- references and numbers as words;
- a stress dictionary for proper names;
- per-verse fragments and current-verse highlighting;
- Hebrew and Greek insertions are skipped.
On mobile — background reading (a foreground service on Android,
background audio mode on iOS).

Voice engine (ADR 0017, 2026-10-06 — neural synthesis and audio Bibles
moved from "after 1.0" to Beta): read-aloud goes through a narrow
`VoiceBackend` in the UI layer — backends `system` (flutter_tts),
`neural` (sherpa_onnx, VITS/Piper on native platforms) and a `file`
stub (audio Bible: files + `marks`). Neural synthesis — a separate
optional component, not in the core (espeak-ng under GPL — package data
is allowed; decided to proceed as planned in ADR 0017, question № 39
closed). Voice packages — directories in `STUDYBIBLE_DATA/voices/`
(vits-piper-* from k2-fsa or a raw Piper .onnx + .onnx.json), import
like modules (a folder or .tar.bz2/.zip via file_picker). Settings:
engine auto/system/neural, per-language voice, speed, per-word
highlighting (exact on system from progress events; estimated on neural
by audio position; exact from `marks` on an audio Bible). The language
frontend on neural: auto-stress by the RUAccent nn_accent neural model
(MIT, tract in `studybible-accent`, the model is an `assets/voice/ru/`
asset, enabled by the "Auto-stress" setting), ё via the yo_words
dictionary, a stress lexicon from the RUAccent dictionary over word
forms of Russian translations, the pronunciation dictionary has
priority; pauses by splitting a verse into phrases at `, ; : . ! ?`
with silence between phrases. On system — choosing the OS engine and
voice in settings. Cloud TTS (Yandex SpeechKit/Azure, chapter cache) —
a postponed question after Beta.
Change (2026-10-12): the neural backend is **temporarily cut from the
build** — `sherpa_onnx`/onnxruntime added ~73 MB of native libraries to
the APK (x3 ABI) and as much to desktop. `NeuralVoiceBackend` remains a
stub, the backend code was removed from HEAD and is recoverable from
git history (`voice_neural_io.dart` before the cut commit); the way
back — ADR 0017 (or a lean sherpa TTS-only build). The `system` engine
stays in the release; tract auto-stress (assets/voice/ru/) is
untouched. The `voiceEngine`/`neuralVoices` settings remain in the
model — the user's packages and chosen voices will survive until the
feature returns.

## Extensions
Five levels — a classification, not a plan.
The foundation — the contribution registry (2026-10-12, ADR 0020):
`ContributionRegistry`, built-in layers/presets are registered with the
same descriptors external plugins will get (`id` immutable after
publication, `kind`, `requires`, `order`); an unknown `typeId` — a soft
skip; the framework (stack, TTS, text renderer) — outside the registry.
An extension package = `manifest.json` + data: `id` (eternal), `api`
(SemVer range), `engine`, `contributes`, `activationEvents`,
`permissions`. Engines — the `data | ui | web` ladder (2026-10-12,
ADR 0020): `data` — `.sbz`+manifest without execution; `ui` — a
declarative DSL rendered by the app (the main path); `web` — WebView, a
fallback hatch. Our own WASM runtime (Component Model/Extism) is
displaced — decided, no longer "being chosen". No general-purpose
computation: the author precomputes the complex as data in `.sbz`.
API v1: data from plugins, a batched output pipeline (per chapter or
screen), UI extension points where the app draws; API = events +
transformers + capability handshake.
Canvas and a plugin's own UI — after 1.0. A full UI replacement is an
alternative frontend through the binding, not a plugin.
API version by SemVer, a plugin has permissions.
iOS: executable plugins are not promised.
The format spec is also written in English by the 1.0 freeze; the API
spec — in English by API v1.

## Network, repositories, AI
Module repositories: currently only the foundation — a port and an
index description (JSON + SHA-256 + signature). Implementation is not
soon. We do not run our own public repository; the user connects an
address themselves.
AI translation and analysis — an optional far-future feature, enabled
only explicitly. Notes are sent nowhere.

## Synchronization
Zip export and import. JSON is the source of truth, the file has a
schema version. Markdown — export only.
A record has: id, updated_at, device_id, revision number. Deletion is
recorded as a tombstone. A tie is resolved deterministically. On a
note-edit conflict both versions are kept (simplified to "newest wins"
in the v1 implementation — see `docs/spec/06-user-data.md`).
Userdata schema v2 (2026-10-08, question № 12, stage B): a record has
the module versification (`vrs`), the module identity (`module_ver` —
content_hash, else version) and a verse check fragment (`context`, up
to 40 chars). Migration 1→2 is ALTER TABLE, old databases and exports
are read (serde default). On creation a record gets the meta and
context from the installed module itself (bridge and CLI).
Re-anchoring `UserData::relink` (calls: `user relink`, a background run
at app start, after a module import): meta matched — the record is
fresh; the module changed — look for `context` in the anchor verse,
then ±2 verses of the same chapter (found — a move with rev+1; not
found — an orphan, the record untouched, its id in the report); records
without context get a fragment of the current verse and fresh meta.
Cross-translation records (stage A, 2026-10-08, user decision):
schema 3 — a canonical org range (`canon_book`, `canon_c1`, `canon_v1`,
`canon_c2`, `canon_v2`), covering verse splits and merges in one form.
In the chapter text — only records of the open translation; foreign
ones — a "records in other translations" button inside your own verse
note's window. The foreign list — the module name and an honest native
coordinate; only for installed modules (records for uninstalled ones
live in the "Records" tab). Tapping a foreign record — navigates to its
verse in its translation + the record window; "back" returns.
The "Records" tab — all records across translations. One mechanism for
notes/bookmarks/highlights; "foreign" = a different `meta.id`. A verse
missing from the target grid — a "no such verse in this translation"
mark.
Module identity is only `meta.id`, the file name plays no role
(2026-10-08, after the stage-A run): the bridge resolves a module by
scanning `modules/` for `meta.id` (fast path — a name match), import
saves the file as `<meta.id>.<ext>` (deduplication, clean names);
relink counts a record "fresh" only when `canon_book` is filled.
Markdown record export — `user export-md` (export only, grouped
module→kind); translation order in comparison is set by arrows in the
picker sheet and in settings (the list is ordered).
Relink orphans: the id list is stored in `meta` (`orphans`, JSON — each
relink run overwrites), the "Records" screen shows them in a "Lost"
section (the text is kept, no jump, deletion — manual).
Record export/import (zip, "newest updated wins") — buttons on the
"Records" screen via file_picker (the entries_export/import /
entries_export_md bridge — wrappers over the core); export — a menu:
.zip or Markdown; on web — a stub.
Alt+←/→ keys and mouse side buttons X1/X2 — steps through the
workspace position stack (desktop, ADR 0019): the same path as PopScope
and the back/forward buttons (`_stackBack`/`_stackForward`).
The version line of post-release fixes is 1.0.1, the list —
`CHANGELOG.md`.
After 1.0: sync through a folder the user chose (their cloud drive, a
flash drive). We have no server.

## Data for reading and study (candidates, verify at Stage 0)
- Synodal, variant (a), the classic 1876 text: eBible.org russyn
  (USFM, public domain, 2022). Stage-0 check: "Иегова" at Gen 22:14,
  Ex 17:15, Judg 6:24. If the name is absent in all these places —
  replace the file with another Synodal source.
  Checked 2026-10-01: "Иегова" in all three places (in Ex 6:3 —
  "Господь"). The file has only 66 books, no non-canonical ones — for
  them a second Synodal source is needed.
- Storage: external texts and the modules built from them live outside
  the repository, in `STUDYBIBLE_DATA` (by default `..\StudyBible-data`
  — a directory next to the repository, not inside). This is by design:
  when the code is published to GitHub the translation texts must not
  end up in the repository, otherwise the account risks a copyright
  strike. Git keeps code, profiles, versifications and pinned SHA-256,
  not the files themselves.
  Sources and pinned SHA-256 — `data/sources.json`; download —
  `scripts/fetch-data.ps1`; content check — `scripts/check-data.ps1`.
- Synodal with Strong's numbers: RST+ (BibleQuote modules, Kravchenko,
  Starikov and Parfenyuk numbering, 1998); github.com/swmail/RST (1876,
  Strong's, headings, cross-references).
- English: WEB — eBible.org engwebp (public domain, without
  deuterocanonicals); KJV — eBible.org eng-kjv2006 (1769, with Strong's
  numbers). Both files — the `eng` versification, not `org`. WEB also
  has Strong's markup, but at Gen 1:1 it is wrong ("In" → H8064) — do
  not use without checking.
- Hebrew and Greek: STEPBible-Data (CC BY 4.0):
  - TAHOT — the Leningrad Codex with morphology, extended Strong's and
    kethiv/qere;
  - TAGNT — the Greek NT with edition marks;
  - TBESH and TBESG — brief lexicons;
  - TFLSJ, TIPNR (proper names);
  - TVTMS (versifications).
  Additionally: WLC, OSHB, MACULA, Nestle 1904, WH, TR, RP.
- Cross-references: OpenBible.info (CC BY, based on TSK), TSK itself.
  The apparatus is injected into ready .sb files after the fact —
  `inject_xrefs` (apps/studybible-cli/src/bin/inject_xrefs.rs): top-8
  links per verse as x-spans (caller '+'), abbreviations taken from the
  module's name_profile (syn/en), coordinates converted from the eng
  versification into the module's versification (org→rsc etc. via
  studybible_core::versification), so Russian modules show psalms in
  their own numbering. All translation and original modules patched:
  russyn, ru_rob, engwebp, eng-kjv2006, englsv, engbsb, ugnt, oshb,
  rstplus.
  Apparatus presentation in the UI: the "×" marker — a text span on an
  accent background (a WidgetSpan+GestureDetector inside a paragraph
  does not accept taps, so we stayed with recognizer); a duplicate
  entry — the "Parallels" button in the selected verse's action panel.
  The second translation in comparison is chosen from all catalog
  modules (on a phone — a bottom sheet by the book icon at the toggle).
- English Strong's lexicon: STEPBible TBESH and TBESG,
  openscriptures/strongs.
- Russian Strong's entries: no open source with a clear provenance was
  found. BibleQuote modules of unknown origin — the user loads them;
  our variant — our own translation of the STEPBible glosses.
- New open sources (Oct 2026):
  - Russian Open Bible — Door43-Catalog/ru_rob (USFM3, CC BY-SA 4.0):
    \zaln-s/\zaln-e alignments with x-strong — scripts/prep-rob.py strips
    the wrappers and moves strong onto \w (167k marks); 23 books without
    alignment. NET Bible rejected: the license forbids hosting on other
    servers; the text has "the LORD", no tetragrammaton.
  - LSV — eBible.org englsv (© Covenant Press, "free to read, distribute,
    and translate from"): YHWH in the text, Strong's on words; no
    apparatus.
  - BSB — eBible.org engbsb (public domain): Strong's + ~4.8k footnotes,
    mostly critical (LXX/MT/DSS/SP/Vulgate) — chosen as the English text
    with a critical apparatus.
  - CARS/NRP/CRTB — closed licenses (quotation limits), not taken.
    Vinokurov (bible.in.ua) — free non-commercially with attribution and
    a site link; its own format, an importer — if needed.
- Russian lemmatization: the OpenCorpora dictionary (CC BY-SA, as a
  separate data file); stemming — Snowball.
- Septuagint (later): Swete — nathans/lxx-swete (CC BY-SA 4.0); we do not
  use Rahlfs.
- Interlinear: built from TAHOT and TAGNT tokens, English glosses and
  Russian glosses (when they appear).

## Documentation
Now: README, LICENSE-MIT, LICENSE-APACHE, docs/SPEC.md as the table of
contents, short ADRs per decision, ROADMAP, OPEN-QUESTIONS.
Sections docs/01–14 (14 — "Voice and accessibility") are written
together with the stage's test fixture.
Sections 05 (module format) and 09 (extensions) get normative form by
the freeze.
Language — Russian; the format — also English by the 1.0 freeze, the
API — by API v1. (2026-10: repository documentation is bilingual —
English primary `.md` files with Russian `.ru.md` counterparts.)

## Test fixtures
- References: 1Кор3:16, Ин 3.16, Ps 22 → Ps 23 org, Synodal and English
  abbreviations.
- Versifications: psalm superscriptions, Joel, Malachi, Ex 7–8, 3 Jn,
  Esther, Rom 14:24–26, Num 26:1, Isa 3:19, Prov 4:28–29 — with the
  expected first words of each verse.
- Canon: marks of non-canonical books and insertions.
- USFM and OSIS round-trip conversion.
- Normalization (Hebrew vowel-mark order).
- Merge: deletion, conflict, skewed clocks.
- Malicious modules.
- Text preparation for voicing.
- Timings: chapter, search, start. Limits recorded, no trials yet
  (question № 11).

## Roadmap and open questions

See [ROADMAP.md](ROADMAP.md) (local only, not published) and
[OPEN-QUESTIONS.md](OPEN-QUESTIONS.md).

Closures of 2026-10-07:
- Android module import verified by the user — question № 25 closed.
- Android stabilization by bug reports finished: all builds checked, no
  bugs.
- Layout/UI package 4 closed: done or replaced by later decisions (the
  mini-player and media session went into Beta, panels — gradient per
  ADR 0015).
- Timelines: № 11 (timing measurements) and № 22 (weak-hardware
  profiling) — the last step before release; № 31 (web dictaphone) —
  someday, no deadline.
- Bridge linkage for the Android API (№ 29 closed):
  `native_toolchain_rust` is vendored in
  `third_party/native_toolchain_rust` with `apiTarget='21'`,
  `dependency_overrides` in pubspec; built-APK control —
  `scripts/check-apk-api.ps1`.
- Non-canonical book coverage by versifications (№ 5 closed): the check
  — on real users (user decision).
- A second Synodal source with non-canonical books (№ 7 closed): not
  needed separately — a full Synodal is built by the
  MyBible/BibleQuote converters if needed.
- Ancient-language search normalization (№ 14 closed): `for_search`
  folds Hebrew final letters (ךםןףץ) to regular, maqqef → space, final
  sigma ς → σ; the normalization version `TOKENIZER_VERSION`='2'
  invalidates `.idx` caches, a built-in `fts` is marked with
  `meta.norm_version`, a mismatch falls back to `.idx` (web — a LIKE
  scan).

Own UI after 1.0 (ADR 0021, 2026-10-12; **revised 2026-10-08** — the
path changed from a GPUI fork to the library one): the Rust library
`studybible-text` of five layers — a ready shaper (HarfBuzz/HarfRust;
we do not write our own shaper, a single stack on all OSes = the text
parity condition), **our own tier composer** on word anchors
(interlinear, columns, apparatus, "text over text" — no toolkit has
this), a single rasterizer (single-atlas vs platform variant — open
until practice), our own GPU compositor (quads, dirty regions — GPUI
ideas), a replaceable shell (Flutter as a texture now, removal
optional). The token and link model (USFM `\zaln`/`\w`, MACULA,
BCVWP) — the foundation: notes, highlights, extensions reference a
token ID. Extensions call the composer in Rust, not widgets. The
GPUI/Slint fork rejected: platform shaping diverges by OS, an embedder
for mobile/web = Flutter's price, no tier model. The three equal
principles remain: reference text quality everywhere in any language;
flawless speed; full customizability. Flutter is the production
frontend; web goes last (the same crate in Wasm).

Changed 2026-10-14 (1.0.1):
- External screens opened from the reader (Search, History, "the verse
  in all translations") are workspace positions kind='screen'
  (pane.screen), not new Navigator routes: a single back/forward stack
  (ADR 0019). The screens got optional onBack/onOpenVerse — an embedded
  mode; when opened from outside (from "Home") the behavior is the
  same — a push route.
- "Share note" — copying to the clipboard (we do not add share_plus:
  the system share sheet drags in platform code, and the "Reference —
  text (translation)" format covers messengers/mail via pasting).
- Fixed: in one of the sources a cross-reference marker binds to a link
  group directly by the marker id. The old positional matching (order +
  anchor verse) broke — "extra" markers got empty text or someone
  else's links.

## Branches and releases (2026-10-15)

Two permanent branches: `main` — releases and tags only, `dev` — all
current work. Tasks lasting days or longer — short `feature/…` /
`fix/…` branches that die after merge. A hotfix — a branch off `main`,
merged into `main` and `dev`. No permanent "experimental": long work
(format v2, `studybible-text`) merges into `dev` in pieces behind a
feature flag (a constant switch in code, like the column comparison).
Cheat sheet and diagram — [BRANCHING.md](BRANCHING.md).

## Book-name profiles (2026-10-16)

A third profile `name_mod`/`abbr_mod` was added to
`data/profiles/books.tsv` — a modern layout of book names (an
alternative to Synodal). In the core — `NameProfile::Modern`
(name search accounts for all profiles). In Flutter — the "Book names"
setting: Synodal / Modern (`settings.bookNames`), applies to short and
full names of canonical books; book names from modules are not
overridden.

## Release builds (2026-10-09)

- `sccache` as rustc-wrapper (`.cargo/config.toml`): a shared
  dependency cache for branches and worktrees.
- `.github/workflows/release.yml`: a release build on a `v*` tag in
  GitHub Actions — Android (3 ABI), Windows x64, Web; artifacts attach
  to the Release. Requires signing-key secrets.
  Not yet applied — only a local file.

## Bridge performance: module connection cache (2026-10-09)

- A module's SQLite connection is opened once per session:
  `api/module.rs` keeps `path → Arc<Mutex<Module>>` in a static map;
  `chapter_doc`, `module_doc`, dictionary and search calls reuse it.
  Before, every call re-read the whole `.sb` file just to sniff the
  `.sbz` magic and reopened the database — a footnote card with a
  dozen cross-references meant a dozen full file reads.
- `open_any` sniffs `.sbz` by the first 4 bytes of the header; the
  full read remains only for actual `.sbz` inputs.
- Dart side: `ModuleDoc.verseTextCache` memoizes single-target verse
  texts — neighbouring notes referencing the same verse do not
  re-slice its chapter. Footnote/cross-ref card results are cached
  per (module, versification, note text) and prefetched in the
  background when a chapter opens (commits 603c111, b4f3263).
