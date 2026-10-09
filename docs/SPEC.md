# StudyBible specification — table of contents

**English** | [Русский](SPEC.ru.md)

This file is only a table of contents. Decisions are recorded in
[DECISIONS.md](DECISIONS.md), rationale in [adr/](adr/). Detailed sections
are written together with the test fixture of their stage.

## Documents

- [DECISIONS.md](DECISIONS.md) — accepted decisions (source of truth).
- [ROADMAP.md](ROADMAP.md) — roadmap and work progress (local only, not
  published).
- [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md) — open questions.
- [BUGS.md](BUGS.md) — log of fixed bugs and flaws.

## Sections

| № | Section | Current location | Status |
|---|---|---|---|
| 01 | Vision | DECISIONS: "Goals", "Principles" | approved |
| 02 | Requirements | DECISIONS: "Measurable requirements" | approved |
| 03 | Architecture | DECISIONS: "Platforms and technologies"; ADR 0001, 0011 | implemented |
| 04 | Data model and coordinates | DECISIONS: "Data and modules"; ADR 0004, 0005, 0006 | implemented |
| 05 | Module format | [spec/05-module-format-v1.md](spec/05-module-format-v1.md) ([English](spec/en/05-module-format-v1.md)); DECISIONS: "Module format v1"; ADR 0003, 0007, 0016 | v1 schema implemented; compact revision (`book_id`, single verse text, span slices); semantics C-1…C-20 fixed 2026-10-12 |
| 06 | User data | [spec/06-user-data.md](spec/06-user-data.md); DECISIONS: "Synchronization"; ADR 0008 | v1 implemented |
| 07 | Search | DECISIONS: "Search"; ADR 0003, 0006 | exact form in FTS5 cache; stemming and phrases — later |
| 08 | Originals and interlinear | DECISIONS: "Data for reading and study" | decisions recorded |
| 09 | Extensions | DECISIONS: "Extensions"; ADR 0009 | normative form by 1.0 |
| 10 | Network, repositories, AI | DECISIONS: "Network, repositories, AI" | post-1.0 |
| 11 | Converter | DECISIONS: "Converter"; ADR 0016 | inputs USFM, OSIS, Zefania, MyBible, BibleQuote, TSV |
| 12 | Interface | DECISIONS: "Interface"; ADR 0012–0015 | Flutter chosen; design system approved by prototype |
| 13 | Sources and licenses | DECISIONS: "Licenses", "Data for reading and study"; ADR 0002 | texts and modules outside git, `STUDYBIBLE_DATA` directory |
| 14 | Voice and accessibility | DECISIONS: "Voice and accessibility"; ADR 0010, 0017 | per-verse TTS, media session; voice engine implemented (system/neural backends, RUAccent, packages); audio Bibles — after 1.0 |

## ADRs

| № | Decision |
|---|---|
| [0001](adr/0001-rust-core-ports-adapters.md) | Rust core, ports and adapters, replaceable UI |
| [0002](adr/0002-licensing.md) | Code MIT OR Apache-2.0, texts separate |
| [0003](adr/0003-sqlite-module-fts-cache.md) | Module = untrusted SQLite, FTS in cache |
| [0004](adr/0004-coordinates.md) | Coordinates instead of a single anchor |
| [0005](adr/0005-versification-canon-as-data.md) | Versifications, canon and book names as data |
| [0006](adr/0006-normalization.md) | NFC for translations, originals as in the source |
| [0007](adr/0007-reading-stream.md) | Reading stream in the module format |
| [0008](adr/0008-user-data-local.md) | User data on device only |
| [0009](adr/0009-extensions-narrow-api.md) | Extensions: narrow API v1 |
| [0010](adr/0010-voice-accessibility.md) | Voice and accessibility |
| [0011](adr/0011-web-last-local-ci.md) | Web last, web-ready foundation, local CI |
| [0012](adr/0012-ui-by-pilot-screen.md) | UI is chosen by a pilot screen |
| [0013](adr/0013-flutter-ui-design.md) | UI: Flutter; pilot-screen design system |
| [0014](adr/0014-workspace-pane-layer.md) | UI as data: Workspace → Pane → Layer |
| [0015](adr/0015-visual-language-reading-study.md) | Visual language "book and vermilion", "Reading" and "Study" modes |
| [0016](adr/0016-module-format-extensions.md) | Optional module format extensions |
| [0017](adr/0017-voice-engine.md) | Voice engine: backends, sherpa-onnx neural synthesis, voice packages |
| [0018](adr/0018-module-format-v2.md) | Module format v2 — post-1.0 roadmap; extensibility beyond the Bible |
| [0019](adr/0019-navigation-workspace.md) | Navigation: unified workspace, position stack, panes without duplicated logic |
| [0020](adr/0020-contributions.md) | Contribution registry and extension engine (data/ui/web) |
| [0021](adr/0021-gpui-ui-track.md) | Custom text system `studybible-text` (post-1.0 track) |
