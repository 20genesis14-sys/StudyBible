# 0019. Navigation: workspace, position stack, panes

**English** | [Русский](0019-navigation-workspace.ru.md)

Status: accepted (2026-10-12, user decisions). Implementation — in the
1.0 scope (question № 21, "navigation back stack").

## Context

Jumps to a scripture place today build a new reading-screen instance on
top of the Navigator stack: each screen is a full reader with its own
data, its own TTS potential and no shared jump history. Chapter swipes
are not reflected in history, there is no "forward" step, and comparison
panes do not fit the "one Navigator per app" model. The user fixed the
main rule: internal logic is not duplicated across panes and instances —
TTS, jump history, search and so on are unique.

## Decision

### Levels of logic ownership

- **The app** owns: the TTS voice engine (one per process — only one
  position is ever voiced, there is no second voicing), the full history
  journal (unbounded, the existing `history`), the cache of loaded
  modules.
- **The workspace** (`ReaderWorkspace`, a data object outside the widget
  tree) owns: the position stack and the pane list. The reading screen
  is only a window into the workspace; a second workspace is allowed
  only for a second OS window (multi-window — a separate later
  decision).
- **A pane** is a view of a position, not a copy of the reader: it has
  no stack, history or services of its own.

### Position stack (short-term memory)

- A position is a generalized `(kind, ref)` record with an extensible
  `kind`: a verse `(module, book, chapter, verse)`, a dictionary entry,
  a commentary place, the apparatus, etc. A position stores a **full
  pane snapshot**: module, layers, layout/reading mode.
- Recorded: swipes across a chapter, jumps by links, transitions from
  other screens, switching the translation on the same place. Scrolling
  inside a chapter is not a jump; the "departure place" is the current
  top verse. A jump to the same position is not recorded.
- "Back"/"forward" step through the stack; a new jump truncates the
  "forward" tail. Limit — 250 jumps. The stack persists between runs:
  start returns to the closing place, "back" steps through the past
  session. The history journal is separate, unbounded; a jump from the
  journal is manual.
- Scroll restoration — to the verse in all layout modes.
- System "back" (Android gesture/button): first closes open sheets and
  cards, then steps through the stack, on an empty stack — leaves the
  reading screen; if the reader is open as the "Bible" tab — goes to
  Home. No back/forward buttons in the reader bar — the stack is driven
  through history (below). Alt+←/→ keys and mouse X1/X2 buttons —
  later.
- App start — on Home (as now); the closing place is reachable via
  "continue reading", the past session's stack is restored in the
  background and "back" steps through it.
- History pane: a "More" menu item in the reader opens a compact pane
  with ‹ › stack steps; expanding opens the existing "History" screen.
- A back step stops TTS.
- The "Compare" screen and the Strong's card are surfaces, not
  positions: they are not written to the stack, "back" closes them; a
  link jump from them writes the target.

### Panes

- One main pane owns the stack and services; additional ones — by a
  formula from screen width/scale (manual adjustment later).
- An additional pane is by default synchronized with the main one
  (`link_group`, ADR 0014) — including through versification
  conversion.
- "Light detach": a pane can show any position (another
  chapter/book/translation/dictionary) independently of the main one.
  Jumps inside a detached pane (a link tap) stay in it and are not
  written to the stack.
- Return to sync mode — the logic exists (a follow flag); the UI button
  — after release.
- TTS reads the main pane's active position; switching the voicing
  source to an additional pane is provided for architecturally (TTS is
  bound to a position, not a widget), implementation — later.

### Implementation

- Variant A: the stack in the Dart layer, `NavEntry` + pointer; system
  "back" via `PopScope` with a dynamic `canPop` (Android predictive
  back).
- `ReaderWorkspace` — a global `ChangeNotifier` singleton in
  `state.dart` next to `settings`/`progress`/`notes`/`history`.
  Provider/get_it are deliberately postponed: the services are eternal
  and unique; the transition is a mechanical refactor when contexts
  appear (profiles, second window, plugins, lazy engines).
- A mode/layer change on the same place is not a jump: the pane
  snapshot updates the current stack record, no new one is created.
  Presets ("Reading"/"Study") are saved layouts editable by the user
  (ADR 0020).
- External jumps (search, bookmarks, plan, history) — the
  `workspace.go(position)` command; the reader is unique
  (`popUntil`/"Bible" tab), no new reading screens are created.
- Evolution paths without changing the model: own Pages inside
  Navigator 2.0 (official back interception and predictive back) and
  Router/URL for the web.

## Implementation status (2026-10-12)

Done in 1.0: `ReaderWorkspace` (`lib/workspace/reader_workspace.dart`,
global singleton `workspace`), generalized `Location` `(kind, ref)`, a
250-entry stack with cursor and persistence (a UserData record
`module='settings'`, `book='WS'`); `PopScope` (search → stack → pop),
internal links and swipes — jumps within the same screen; translation
switch — a jump; the pane snapshot (`interleaved`/`cmp`/`cmps`) updates
the current record; compact ‹ › in the "More" sheet; TTS stops on a
jump; `PaneConfig.followsMain` — "follows main" state in the model.
**Not done yet:** additional panes and their formula/detach UI, external
screens jumping via `workspace.go` without a new route (`popUntil`), a
"attach pane" button, keys/mouse buttons — after release. Known minor
issue: with two live reading screens the lower one shows its previous
place, while the stack is single.

## Consequences

- "Continue reading" and session restore — free: the workspace
  serializes into userdata.
- Layouts, tabs, screen splitting — new ways to show the same model;
  the logic is untouched (the customization foundation of ADR 0014).
- Tests must cover: system "back" interception (gesture and predictive
  back), "forward" truncation, stack persistence, pane detach/sync, TTS
  stop on a back step.
