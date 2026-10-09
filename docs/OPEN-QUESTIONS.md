# OPEN-QUESTIONS.md — open questions

**English** | [Русский](OPEN-QUESTIONS.ru.md)

The questions below have not been checked on the target devices. They
concern the riskiest spots in the spec; resolving them early reduces the
cost of later rework. Each is formulated so that the answer is observable
— a measurement, a prototype, a user check.

## Priorities for early resolution

| № | Question | How to check | If the answer is no |
|---|---|---|---|
| 1 | GPUI (gpui.rs) — is it ready for real work: Skia/HarfBuzz shaping, RTL, virtualized lists? | Pilot screen prototype: long chapter, Hebrew with vowel points, 120 fps on a modest GPU | Alternative: egui/wgpu or a custom canvas text-renderer; decision by the pilot |
| 2 | Will the WASM build of the SQLite core survive: OPFS on iOS Safari, file import, UI freezes? | Prototype: .sb import, search, reading — in Safari 15/Chrome | Fallback: sql.js/sqlite3.wasm without OPFS; data in IndexedDB |
| 3 | Does the neural RU voice synthesizer (MIT) run in real time on an Android phone? | sherpa-onnx/Matcha on a mid-range device; measure RTF and startup | Fallback: cloud TTS or a smaller model; voice packages ~50–150 MB |
| 4 | Original-language texts with a critical apparatus — legal status and quality of open sources? | Compile the real list (SBLGNT is non-commercial), check the apparatus completeness | Limit the selection (OSHB, WH); apparatus in a reduced form |
| 5 | Does the spec cover non-Bible corpora (Fathers, documents)? | Try to describe 2–3 document types within the v2 module model | Extend the schema — decision before the corpus expansion stage |
| 6 | Is 6 months realistic to 1.0 (book → verse → reading, user data)? | Plan by stages; the pilot week gives a point on the curve | Trim to a release slice ("reading + notes"), the rest into 1.x |
| 7 | Community extension API — demand? | Hypothesis check: will the community write data-packs/JS on the narrow API | Ship v1 without web-views and dynamic code |
| 8 | Does user-data sync via a file work (WebDAV/drive)? | Prototype with conflicts of two devices and attachments | Bring-your-own-file: the user manages the DB file themselves |
| 9 | Stress dictionary for the neural TTS — coverage? | Automatic accentuation of a corpus; error share (Church Slavonic, names) | Manual dictionary + letter-for-letter fallback |
| 10 | iOS < 15 — give up right away or check? | Web prototype on an old iPad | Declare iOS 15+ the minimum |

## Open questions

| № | Question | How to check | If the answer is no |
|---|---|---|---|
| 11 | Linux build (Flutter desktop + Rust FFI) — does it actually build and run? | `flutter build linux`, run, 3 smoke scenarios | Postpone the platform; record in DECISIONS |
| 12 | Are fragments of a bible text selectable (highlight/note/quote) in all modes? | Prototype selection on a chapter | Implement own selection on canvas hit-test |
| 13 | Would parallel columns (translation + original/commentary) be convenient on a phone? | UX check on a narrow screen | Inline mode only |
| 14 | Automatic interlinear alignment — acceptable quality? | Prototype on 2 chapters, error share | Statuses `auto`/`verified`, a mark in the UI |
| 15 | RUAccent for the neural TTS — quality on Bible vocabulary? | Listen to fragments | Manual dictionary + mark `unstressed` |
| 16 | Interactive zoom on diagrams (timeline map) — needed in 1.0? | Decide by scenarios | Static diagrams + pan/zoom |
| 17 | Search with word forms (stemming/morphology) — needed in 1.0? | Evaluate the query-to-hit ratio | Exact/prefix in 1.0; morphology — later |
| 18 | Private `.sbz` modules via signatures — needed in v1? | Decide by the threat model | No signatures; SHA-256 integrity |
| 19 | Are packaged voice-package/lexicon resources needed? | Evaluate sizes (50–150 MB) | Download on demand |
| 20 | Export of user data (JSON/Markdown) — needed in 1.0? | Decide by the "data ownership" principle | Postpone to 1.x |
| 21 | Cloud sync via an external file — implement in 1.0? | Conflict prototype | Postpone to 1.x |
| 22 | Is the 120 fps budget with Hebrew + shaping achievable on the target devices? | Pilot screen on a weak device | 60 fps + pre-render; profile the DOM |
| 23 | Are the statistics charts (read/enrichment) needed in 1.0? | Decide by the "Study" profile | Postpone to 1.x |
| 24 | Plugin API for external modules (WASM) — needed in v1? | Decide by the security model | Contribution-model only |
| 25 | Licensing of original texts — is a legal check needed for the target list? | List of editions + licenses | Limit to public domain |
| 26 | macOS: a separate build is needed — does the team have a build machine? | Hardware/cloud check | Postpone the platform; community builds |
| 27 | Text size inside a module without compression — do we fit the limit? | Sizes of real corpora | Chunked ZIP (sbz) |
| 28 | The parallel-places/interlinear apparatus — ready sources? | Compile the list of open apparatuses | Generate it ourselves from concordances |
| 29 | Hebrew cantillation and accents — to display them? | Decide by the target audience | Optionally |
| 30 | Strong's dictionary — is a modern correction needed (Tsygankov, BDAG)? | Rights/availability check | Open dictionaries only |

## Resolved (closed)

| № | Question | Answer |
|---|---|---|
| 22 | 120 fps + Hebrew on target devices | Weak-device check passed: ~30–45 fps with jank on inline comparison; acceptable in 1.0. Improvement — rendering package B |
| 11 | Linux build | Works: 0.65 s start, ~60 fps reading, instant search |
| 12 | Text selection | Working via a custom toolbar (copy/highlight/note/bookmark/tag) |
| 13 | Parallel columns on a phone | Works in inline mode (line under line) |
| 17 | Morphological search in 1.0 | Exact + prefix FTS5; morphology — later |
| 18 | Signatures for .sbz | Not needed in v1; SHA-256 integrity |
| 20 | User-data export | In 1.0 — JSON export |
| 22 (old) | Performance | Closed, see №22 above |
