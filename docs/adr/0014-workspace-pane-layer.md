# 0014. UI as data: Workspace → Pane → Layer

**English** | [Русский](0014-workspace-pane-layer.ru.md)

Status: accepted (2026-10-05).

## Context

The reading screen (`reading_screen.dart`, ~3600 lines, 34 `setState`)
holds in a single state the position, layout, modules, comparison,
interlinear, read-aloud, selection, notes and swiping. Adding a new pane
or layer is hard.
The post-1.0 goal is full user customization of the UI (moving panes,
translations, UI parts) on Android, desktop and web.

## Decision

The UI is described by data (JSON in userdata):

```
Workspace  layout: single | split(h|v, ratio) | tabs;  panes: [Pane]
Pane       type: reader | lexicon | notes | search | commentary | plugin:<id>
           source: module id or "main translation"
           link_group: panes of one group stay in sync by verse
           layers: [Layer]
Layer      type: text | second_translation | interlinear | footnotes | xrefs
                 | strongs | apparatus | notes;  options: {...}
```

- A phone shows one pane and bottom sheets; tablet and desktop — panes
  side by side.
- Presets ("Reading", "Study", "Comparison") — ready-made JSON.
- Layers are extension points for plugins (ADR 0009: the plugin supplies
  data, the app draws).
- The reading screen is split: `ReaderController` (state without
  widgets), `ChapterRenderer` (chapter + layers → lines, a pure
  function), `ReaderPane` (the pane widget), separate `TtsService`,
  `PageSwipe`, sheets and dialogs.
- Layout editor (drag-and-drop) — after 1.0; the model is introduced
  now.
- First implementation: the `WorkspaceConfig`/`PaneConfig`/`LayerConfig`
  model serializes to JSON but is not yet written to userdata —
  persistence and preset selection arrive together with the layout
  editor. The reading screen is split into `reader_controller.dart`
  (navigation, loading, records), `chapter_renderer.dart` (spans and all
  chapter layouts), `reader_pane.dart` (reading area and comparison),
  `reader_chrome.dart` (top/bottom bars, mini-player and action panel),
  `page_swipe.dart` (page gesture), `tts_service.dart` (TTS queue and
  media session), `notes_sheet.dart` and `reader_dialogs.dart`
  (footnotes, notes, tags, Strong's card).
- At the first split step the shared methods remain `part` extensions of
  `_ReadingScreenState`: this preserves access to one state without
  rewriting all callbacks. Fields and lifecycle stay in
  `reading_screen.dart`; the next step may replace the extensions with
  standalone classes with explicit display contexts.

## Consequences

- One Flutter codebase on all platforms reads one model.
- Moving a block is a JSON change, not a screen rework.
- The transition happens without changing the look; behavior is checked
  against screenshots.

## Update 2026-10-18 — same-translation panes and optional link groups

`source` and the reading position are independent per pane: two panes
may open the **same** translation at **different** places — another
verse of the same chapter, another chapter, another book. The position
becomes a per-pane map; the ADR 0019 stack stores pane-position
snapshots. `link_group` is optional by design: `null` — independent
pane (several different passages on one screen); `"main"` — follows the
main pane by verse; arbitrary group ids give multiple sync groups
(e.g. a `ru` pair and an `en` pair, independent of each other). Verse
sync across different translations goes through
`Versification::convert`; same-translation panes need no conversion.
UI: a link toggle in each pane header; presets set the defaults
(«Сравнение» — all linked, «Места» — all independent). Active-pane
rule: TTS, history and reading progress follow the focused pane.
