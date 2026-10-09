# 0020. Contribution registry and extension engine

**English** | [Русский](0020-contributions.ru.md)

Status: accepted (2026-10-12, user decisions). The contribution
registry — in the 1.0 scope (the foundation under № 21 and
customization); external extensions — after 1.0.

## Context

New display forms (comparison of 3+ translations, apparatus,
lemmatization) and future plugins need a single way to add "what to show
and where", not new flags in the reader monolith. The survey of mature
extension systems ("Extension best practices", the user's document)
gives a stable set of rules: two layers — data and code; a manifest
without running code; events and transformers; lazy activation;
lifecycle and migrations; one owner per slot; an error names the
extension; flagship extensions are checked in the host's CI.

## Decision

### Contribution registry — the foundation, in 1.0

- `ContributionRegistry`: `register(typeId, descriptor)` +
  `resolve(typeId)`. Descriptor: `id` (immutable after publication —
  the SMAPI rule), `kind` (`layer | pane | action | preset`), `title`,
  `requires` (data/capabilities, e.g. `tokens`), `order` (priority on a
  slot conflict), `builder`.
- **Our features are the first contributions.** Layers (comparison,
  interlinear, footnotes), verse-menu actions, the "Reading"/"Study"
  presets are registered through the registry with the same descriptor
  external plugins will get. The renderer iterates
  `layers.map(resolve)` instead of a switch over types.
- The framework stays outside the registry: position stack, TTS, the
  text-stream renderer, navigation, panes. "Everything is a
  contribution" rejected (the Eclipse trap).
- An unknown `typeId` in a saved layout — a soft skip (the "unknown is
  ignored" rule, as in the module format).
- A layer declares data needs (`needsData`), the controller collects
  them in one batch per chapter — the batch pipeline from ADR 0009.

### Extension engine — an engine ladder, after 1.0

An extension package = `manifest.json` + data (+ resources). Manifest:
`id` (eternal), `api` (SemVer range), `engine`, `contributes` (which
points: layer/pane/action/dictionary/settings), `activationEvents`
(lazy start), `permissions`.

- `engine: "data"` — a `.sbz` package + manifest: dictionaries,
  commentaries, apparatus, plans. Zero engine, almost done already.
- `engine: "ui"` — a declarative DSL: a JSON view tree + data queries +
  a small expression language; our Flutter code renders it. The main
  path — no WebView seam, no iOS review risk, theme and accessibility
  apply by construction.
- `engine: "web"` — a fallback hatch: HTML/JS/WASM in the system WebView
  (legal on iOS — Apple's WebKit runs the code), whole screens only,
  network by allowlist. Not implemented in the foreseeable future.
- No general-purpose computation and never will be: anything complex the
  author precomputes at home and ships as data in `.sbz`. A real need
  for executable code is the signal to open the `web` rung.

### Extension API rules (fixed in advance)

- The API is split into **events** (listens — `chapterOpened` etc.) and
  **transformers** (gets a batch — returns a value); prefixed names,
  forever.
- Capability handshake on activation instead of "we support all
  versions".
- A plugin gets a scoped store in userdata with its own schema version
  and migrations; `id` is immutable after publication.
- One owner per contested slot; user settings outrank plugin
  contributions; errors name the extension, the host survives.
- Plugin settings — a declarative schema drawn by the shared settings
  screen, not by the plugin.

### What we deliberately do not do

- Service locator/Provider/get_it — while services are "eternal and
  unique" (global `ChangeNotifier` in `state.dart`). The transition is a
  mechanical refactor when contexts appear (profiles, second window,
  plugins, lazy engines).
- Our own WASM runtime (Component Model/Extism) — displaced by the
  `ui` + `web` pair.
- Store/signatures — until the catalog; the package format reserves room
  for a signature. Restricted mode (plugins off by default) — an open
  question for API v1.

## Implementation status (2026-10-12)

In 1.0 the minimal foundation is done: `ContributionRegistry`
(`lib/workspace/contributions.dart`) with `id/kind/title/subtitle/
requires/order` descriptors; built-in layers and presets are registered
in the same format. The "Layers" sheet builds rows from the registry
with a `requires` filter on module `features`; an unknown `typeId` — a
soft skip. **Not done yet:** `layers.map(resolve)` iteration in the
renderer itself (layers are still drawn by built-in code), `action`/
`pane` contributions, the `needsData` batch, the DSL — after 1.0.

A separate normative document (section 09 in `docs/spec/`) is not
written — decision of 2026-10-12: the "Extensions" section in DECISIONS
points to this ADR; the normative API spec (Russian and English) ships
together with API v1 after 1.0.

## Consequences

- Comparison of 3+ translations = a `compare` layer with a `modules`
  list; multi-column comparison — synchronized additional panes
  (ADR 0019), not a mode.
- The "Reading"/"Study" presets are saved layouts editable by the user;
  the layout editor (after 1.0) writes the same JSON.
- The external extension API is hardened on the built-in contributions
  before publication — the "flagships in CI" discipline.
