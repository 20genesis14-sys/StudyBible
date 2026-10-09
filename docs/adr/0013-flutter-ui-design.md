# 0013. UI: Flutter, pilot-screen design system

**English** | [Русский](0013-flutter-ui-design.ru.md)

Status: accepted (UI choice — Flutter). The bottom menu and marker
presentation are superseded by ADR 0015; tile saturation and full book
names are refined there too.

## Context

Per ADR 0012 the UI was being chosen by a pilot screen between Slint and
Flutter. First two mockups were built in Figma (the pilot screen per the
ADR 0012 checklist and the "book grid → chapter grid → reading" flow for
mobile and desktop), then a live Flutter prototype
(`apps/studybible-flutter`) on real texts from the russyn / engwebp /
eng-kjv2006 modules. After the demonstration the user chose Flutter; the
Slint pilot screen is not built — no letter to SixtyFPS needed.

## Decision

UI — Flutter, binding to the core — flutter_rust_bridge (thin, as
recorded in DECISIONS "Platforms and technologies").

Approved pilot-screen decisions (prototype → application):

- **Canon navigation.** Books — a continuous grid (no breaks by groups)
  in two blocks: Hebrew Scriptures / Christian Greek Scriptures; book
  groups differ only by tile color. Chapters — a grid. Chapter paging by
  swipe and ← → keys, across book boundaries with an "End of X → Y"
  banner. Optional verse picker (a toggle in settings).
- **Book groups.** 10 groups with a signature color (Pentateuch —
  indigo, historical — emerald, poetic — amber, major prophets — violet,
  minor prophets — dark pink; Gospels — blue, Acts — turquoise, Paul's
  epistles — terracotta, general epistles — olive, Revelation —
  graphite). White text on the tile, contrast ≥ 4.5:1. Verse numbers in
  the chapter text — in the book-group color, bold. The "neutral tile +
  colored stripe" variant was rejected: reads worse on screen.
- **Text layout.** Two modes: paragraphs (indent, 1.66 line height) and
  "verse per line" (tighter spacing). Font size — a slider and
  Ctrl+wheel. Column width — a "Reading" option (~720 px centered; long
  lines are uncomfortable on desktop).
- **Verse interaction.** Tap a verse number → action panel (highlight,
  note, copy, share, compare) and, on a wide screen, a "Footnotes and
  parallels" side panel with footnotes bound to verses. Double-tap a
  verse → translation comparison mode. Tap a word with a Strong's tag →
  the word card. Mouse text selection for copying.
- **Themes.** Light; dark "for the eyes" (dark gray); AMOLED (pure
  black). Planned: sepia and warm tones — the theme architecture allows
  it.
- **Reading fonts.** Bundled Literata (default, for screen reading) and
  Gentium Book Plus (reserve for Hebrew/Greek); system — an option.
- **Progress.** A read chapter — a checkmark chip and a colored frame on
  the tile; an "N of chapters" bar in the book header; a "continue"
  marker; autoscroll to the last verse on reopening a chapter; a thin
  scroll bar under the header. Held in prototype memory for now;
  persistent storage — via `store::UserData` in the app.
- **Bottom menu (mobile).** Home / Bible / Reading schedule /
  Dictionaries / Settings — the last three are stubs for future
  sections.

## Consequences

- Plugins do not draw their own UI until API v1 (as in ADR 0009).
- The public web preview of the prototype is a static snapshot at deploy
  time (`web-*.devinapps.com`), not part of the product; web remains "at
  the very end" per ADR 0011.
- The prototype reads preloaded JSON; the app reads `.sb` modules
  directly through the bridge. User modules (e.g. built from submitted
  sources) are user data, not part of the repository or public build.
