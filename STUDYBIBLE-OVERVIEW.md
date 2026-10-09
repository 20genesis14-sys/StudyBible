# StudyBible — application overview for review

**English** | [Русский](STUDYBIBLE-OVERVIEW.ru.md)

A brief extract on the structure and interface of the Bible study app.
Status: working prototype (Alpha); target platforms — Android, Windows, Web.
Hard requirement: 120 fps and complex typography (Hebrew/Greek with
vowel points, diacritics, RTL).

## Stack and architecture

- **Rust core** (`crates/`): parsing and storage of `.sb` modules (SQLite),
  search (FTS5), versification, user data (`userdata.db`).
- **Flutter UI** (`apps/studybible-flutter`): one app for
  Android/Windows/web. Bridge to the core — flutter_rust_bridge (FFI); on
  web — sqlite3.wasm reads the same `.sb` files.
- **`.sb` modules** — Bible translations, dictionaries, commentaries,
  original languages, interlinears. Separate from the repository; the user
  imports `.sb` files. 8 are bundled: Synodal (1876), Russian Open Bible
  (CC BY-SA, ~167k Strong's tags), WEB, KJV 2006, LSV
  (YHWH in the text, ~706k Strong's), BSB (public domain, ~4.8k
  critical notes LXX/MT/DSS/SP), OSHb (Hebrew WLC, Strong's),
  UGNT (Greek). All have the OpenBible cross-reference apparatus
  injected (top-8 links per verse, versification conversion —
  Ps 22 English = Ps 21 Russian). A personal interlinear module
  (Kingdom Interlinear, NT) — "gloss above WH Greek" pairs.
- **userdata.db** — notes, bookmarks, highlights, tags, reading
  progress, history, settings (JSON).

## Accepted design changes (2026-10-05, not yet in code)

UI model Workspace → Pane → Layer (ADR 0014); visual language
"book and vermilion", "Reading"/"Study" modes, the "Layers" sheet, bottom
bar Translation · Layers · Listen · More, book grid with saturation
−15–20 % (ADR 0015); bottom navigation Home · Bible · Plan · Records ·
Library and the "Plan" screen (ADR 0015); optional module format
extensions (ADR 0016). The current state of the app is described below.

## Navigation

Bottom navigation — 5 tabs: **Home · Bible · Schedule · Modules ·
Settings**. All transitions are quick ~160–200 ms animations (shift+fade);
theme change — a smooth ~200 ms crossfade.

## Screens

### Home (08-home.png)
- "Continue reading" — a card with the last position (book + chapter),
  opens on tap.
- "Verse of the day" — rotates by date; a tap opens the chapter at the
  right verse.
- "Recently read" — chips of the last chapters (from unified history).
- Quick actions: Search / Modules / Bookmarks / History / Schedule.
- "Reading schedule" — percentage read (chapters marked out of 1189).

### Bible (01-bible-books.png)
- The book grid follows the module's contents: books not present are
  hidden (an NT-only module shows no empty OT); books outside the 66-book
  canon get a separate "NON-CANONICAL BOOKS" section. Tile color marks
  the group (Pentateuch, historical, poetic, prophets, etc.).
- On top: a **"Translation"** chip — quick selection of the main
  translation (a sheet listing found modules) + a book-name search field.
- Tapping a book → chapter grid (02-chapters.png): chapter numbers, read
  ones with a checkmark, current chapter with an accent border, book
  progress bar and "read/total" counter. Optionally a verse picker when
  selecting a chapter (a toggle in settings).

### Reading (03-reading-paragraphs.png, 04-reading-verses-web.png, 13-dark-theme.png)

Three text layouts: **Paragraphs** (like a printed Bible), **By verses**
(each verse a line, large number on the left), **Book** (infinite scroll
of the whole book with "Chapter N" headings). Switching — in Settings,
instant.

- Top bar: "back" · "Book Ch." · "Search in text" pill. The book title is
  truncated to ~12 chars with ellipsis — search is always visible.
- Bottom bar (mobile): 6 colored actions — translation, translation
  comparison, interlinear, read aloud, history, footnotes. No chapter
  arrows — chapters turn by swipe.
- Both panels are "liquid glass" (BackdropFilter σ2 + 30 % fill + white
  rim): text is readable through the panel. They hide on scroll and
  return on tap.
- **Chapter swipe — page animation**: the page follows the finger, the
  adjacent chapter slides in next to it (both visible); holding the
  finger stops the transition in place; releasing — completion or
  rollback (~190 ms). In "Book" mode a swipe turns whole books.
- **Verse navigation** works in all three layouts: an anchor on the verse
  number; in the book ribbon — forced frames and direct jumpTo
  (previously it "didn't reach" distant chapters).
- **Text selection**: long tap → selection → a custom icon toolbar:
  copy / highlight color / note / bookmark / tags; then system items.
  Notes support attachments (images, audio dictation).
- **Footnotes and cross-references**: the "×" marker (or "*" for regular
  footnotes) after a verse — an accent chip; a tap opens a bottom sheet
  with the chapter's references; the selected verse's footnote is framed;
  links inside are tappable (jump to the verse). A duplicate entry —
  the "Parallels" button in the selected verse's action panel.
- **Translation comparison**: next to/under the verse — the second
  translation's text; the second translation can be any module (on a
  phone — a book icon near the "Main/…" switch, a bottom sheet). There is
  an inline comparison mode (line under line).
- **Interlinear pairs**: interlinear modules ("gloss over original"
  pairs, e.g. Kingdom Interlinear) render as word-above-word columns in
  all layouts and in inline comparison.
- **Interlinear**: for original-language modules (OSHB/UGNT) — a second
  line "word for word" with a gloss from Strong's dictionary; Hebrew RTL
  with vowel points.
- **Strong's**: in modules with numbers (KJV-2006, RST+) tapping a word
  opens the dictionary entry card (lemma, transliteration, definitions,
  KJV).
- **Read aloud** (05, 06): start via the icon; a mini-player above the
  bottom bar — ‹/› by verses, pause, stop, verse number, **draggable
  progress slider**; the current verse is highlighted and the screen
  follows the reading. Android media session — a card in the shade,
  headset buttons.

### Search (07-search.png)
Query field + module selection. FTS over `.sb`, snippets with highlight,
tapping a result → reading at that spot. The query is written to history.

### History (09-history.png)
A unified feed across all modules: opened chapters (with translation name
and verse), Strong's dictionary entries, search queries. A tap restores
the context: the same chapter/verse in the same translation, the
dictionary card, the search screen with the same query.

### Bookmarks (14-bookmarks.png)
A list of bookmarks (module + place + fragment) and grouping by tags
with filter chips. A tap — jumps to the place.

### Modules (10-modules.png)
A list of found modules (id, title) with tags like
"critical apparatus", "critical text", "original · Hebrew/Greek".
An "Import .sb" button (file_picker → copies to the data directory).
Strong's dictionary — 14 298 entries + Tsygankov's Russian dictionary
(8 674 Hebrew + 5 523 Greek), search by number/lemma/word.

### Settings (11, 12)
Appearance (light/dark/AMOLED; sepia and warm tones — planned),
UI language (ru/en), text font (Literata/Gentium/system) and scale
×0.8–1.6 with live preview, layout (paragraphs/verses/book), column
width for desktop, the verse-picker toggle, **main translation** (applies
at startup and in all navigation without an explicit choice), progress
reset. Everything is saved to userdata and survives restart.

## Reading flow (typical scenario)

1. Home → "Continue reading" or Bible → book → chapter (→ verse).
2. Read: paragraphs, colored verse numbers; panels hide on scroll.
3. Swipe — adjacent chapter with a page animation following the finger
   (in "Book" mode — the adjacent book in whole).
4. Long tap on text — highlight/note/bookmark/tag.
5. Listen: the read-aloud icon → mini-player, drag the slider.
6. Cross-references — tap "×" near the verse or the "Parallels" button;
   Strong's — tap an underlined word; translation comparison — the icon
   in the panel, second translation is chosen from a list.
7. Return: History (any chapter/dictionary/search) or "Continue reading".

## User data (userdata.db)

A single records table `kind ∈ {note, mark, hl, tag}` with an anchor
(module, book, chapter, verse). Service records of the same type:
history (`text='hist*'`), settings (`module='settings'`),
progress (`module='*'`). Plus note attachments — files in the data
directory.

## Known prototype limitations

- Sepia/warm tones — placeholders ("soon").
- "Schedule" — so far only a read-chapters counter (reading plans —
  after 1.0).
- TTS on Android — the system engine (a Russian voice is needed;
  offline neural — on the roadmap).
- On web there is no userdata persistence (localStorage partial), the
  dictaphone is hidden.
- Web serving: modules — `modules/*.sb.gz` (gzip -9, 313→123 MB),
  decompressed by the browser's DecompressionStream; the list —
  `index.json`. Deploy transfer limit ~130 MB, so the site carries 6 of 8
  modules — KJV 2006 and LSV are imported as files.
- User packages/modules are imported manually as files.

## Future plans (context for suggestions)

- Reading plans and a progress schedule (the "Schedule" screen is a
  counter for now);
- SWORD/MyBible/BibleQuote converters, module repositories;
- user data synchronization between devices;
- audio Bibles, offline neural synthesis with a stress dictionary;
- extension API (plugins), iOS build;
- lemmatization, Septuagint (the book grid already supports
  non-canonical books), apparatus expansion (variant readings like BSB —
  in Russian), semantic search.

## Purpose of the review

Advice on **original but practical design** is wanted — both for the
interface and for the internal structure of the app, including the future
plans above (a design that scales and will not need rework for new
features). What to look at:

- information architecture, navigation, screen density and hierarchy;
- gestures, animations, accessibility, reading typography (including
  Hebrew/Greek and interlinear);
- the "liquid glass" visual language, color accents, empty states;
- distinctiveness while staying practical — the app is read for hours,
  design must not get in the text's way;
- architectural decisions that simplify future plans
  (plugins, sync, audio, reading plans).

Screenshots are attached to the report.
