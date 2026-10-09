# OPEN-QUESTIONS.md — open questions

**English** | [Русский](OPEN-QUESTIONS.ru.md)

| # | Question | When to resolve |
|---|---|---|
| 2 | ~~Russian Strong's glosses~~ — closed: the Russian Strong's dictionary (Yu. A. Tsygankov, "Bible for All", 2005) is overlaid on top of the English one | closed |
| 3 | Plugin technology — direction decided (ADR 0020): the `data | ui | web` ladder, declarative DSL is the main path, a custom WASM runtime is superseded; DSL details and restricted mode — by API v1 | By API v1 |
| 4 | Apple's policy on downloaded WASM | May stay unknown until a build is submitted |
| 5 | ~~Versification coverage of deuterocanonical books~~ — closed: checked on real users (user's decision) | closed |
| 7 | ~~A second Synodal source with deuterocanonical books~~ — closed: decided by the user; the full Synodal text is assembled by the MyBible/BibleQuote converters if needed | closed |
| 8 | ~~Unequal ranges in `.vrs`~~ — closed: our rule (the longer side's surplus goes to the shorter side's last verse) is kept; verified against the libpalaso source — Paratext overwrites mappings with the last line, our rule is more precise on Ps 89/90 and Ps 141/142; translation comparison goes through the core versification (DECISIONS) | closed |
| 9 | ~~Verse 0 (psalm superscriptions)~~ — closed: in comparison the superscription is a separate "superscription" row above the first verse on both sides (variant A); if the superscription is inside verse 1 of a translation, the row is empty | closed |
| 10 | ~~Corrupted lines in vul.vrs~~ — closed: upstream libpalaso matches byte-for-byte, the typos are there too; fixed locally with a comment: `DAG 3:52-23`→`3:52-53`, `DAG 13:1-63 = SUS 1:63`→`SUS 1:1-63`, `DAG 14:1-42 = BEL 1:42`→`BEL 1:1-42` | closed |
| 11 | Timing measurements, desktop (2026-10-12, `test/bench_test.dart`): chapter 11–17 ms (limit 50), search 12–21 ms (limit 200) — cold search sped up: FTS5 is embedded in every `.sb` (`module index`, `"fts": true` in modules.json), the external `.idx` is no longer built; the Dart bridge reads the embedded FTS itself (on `norm_version` mismatch it falls back to `LIKE`; on web it is case-sensitive — the limitation is recorded). Module 19–110 ms, first loadModule 848 ms after fix `d47c3af`. Windows cold start: profile first frame 1486 ms (`build/start_up_info.json`); release exe to window: **~2.2–2.8 s → ~1.7–1.95 s** after adding the folder to Defender exclusions (4 cold runs, `C:\StudyBible-tools\measure-start.ps1`) — Defender was eating ~0.5–1 s scanning .dll; the remainder is engine/VM + OS load (`main()` ~38 ms). Next levers: keep-alive/auto-warmup. Left: a run on weak hardware/phone | Before release — on a device |
| 12 | 2026-10-08 — stages B and A done (v1.0.1): schema 3 (`vrs`, `module_ver`, canonical org range), auto-context, `UserData::relink`, `entries_foreign` — foreign entries via a button in the note sheet, installed modules only; the "Notes" tab groups by translation; tap — jump to its translation + entry sheet. Left: user run on real data | User run |
| 13 | ~~Verse segments (`ESG 1:1a` and similar) discarded down to the number during parsing~~ — closed: binding to the verse part (`part`/`q`, `\fr`/`\xo`, `<catchWord>`) is preserved by the converters and shown in the UI ("v.1a", binding quote); navigation goes to the whole verse | closed |
| 14 | ~~Hebrew normalization and final sigma~~ — closed: `for_search` folds Hebrew final letters (ךםןףץ) to the regular ones, maqaf U+05BE → space, ς→σ; the `meta.norm_version` normalization version in the module and in the `.idx` cache key; the web bridge repeats the same rules | closed |
| 15 | ~~Module rights flags~~ — closed: optional `meta.rights` = `no-distribute`, `no-net`, `no-ai`, `no-plugins` (ADR 0016) | closed |
| 16 | ~~ADR 0012 checklist~~ — closed: synchronized scrolling, book feed, plan screen done; OS font scale — the Flutter system default | closed |
| 17 | ~~Ancient-language fonts~~ — closed: NotoSerifHebrew (he/hbo/arc), GentiumBookPlus (grc/el) bundled | closed |
| 18 | ~~Web path~~ — closed: sqlite3.wasm reads .sb in the browser, `--wasm` build (skwasm), COOP/COEP + gzip in serve_web.py | closed |
| 19 | ~~Read-aloud with highlighting~~ — closed: TTS reads a chapter verse by verse with highlighting, mini-player, Android media session | closed |
| 20 | ~~Reading history~~ — done: `Kind::Mark` entries with text="hist", no limit, "History" screen | closed |
| 21 | ~~Pinch-zoom on text; timed auto-night mode; 3+ translation comparison; navigation back-stack~~ — closed: all four implemented (pinch-zoom — `2de3816`; contribution registry — `d7b0702`; `ReaderWorkspace` with a 250-entry stack + `PopScope` — `144396b`; inline comparison with module list and timed auto-night — `6fbcce1`; ADR 0019/0020) | closed |
| 22 | ~~Performance on weak hardware~~ — closed: run on a real ~6+ year old Huawei — the app is stable and fast. Earlier AVD/web/Linux runs were fine too. The known web limitations stay recorded as fact: the search result list is monolithic, .sb fully in RAM | closed |
| 23 | ~~Web: FTS index in the browser~~ — closed: optional `fts` table (FTS5) inside `.sb` (`"fts": true` in modules.json, ADR 0016 §11); without it the reader builds the `.idx` cache as before | closed |
| 24 | userdata diverges between web and desktop (web on localStorage); zip export/import exists in the core — to be closed by synchronization | Until sync |
| 25 | ~~Module import on iOS/Android~~ — closed: import verified by the user on Android | closed |
| 26 | ~~"Verse of the day"~~ — closed: 2026 daily schedule (assets/data/daily.json), references only, text taken from the selected module | closed |
| 28 | ~~"Infinite book" mode~~ — closed: `LayoutMode.book`, book feed with chapter headings, lazy loading | closed |
| 29 | ~~Bridge linking against Android API~~ — closed: `native_toolchain_rust` 1.0.7 vendored into `apps/studybible-flutter/third_party/native_toolchain_rust` with `apiTarget = '21'`, wired via `dependency_overrides` (pub-cache patch no longer needed); control — `scripts/check-apk-api.ps1` on the built APK | closed |
| 30 | ~~Audio button in the reading panel~~ — closed: read-aloud exists (button/mini-player, media session) | closed |
| 31 | Web voice recorder for attachments: `record` supports MediaRecorder, but files are local — localStorage storage is limited to ~2 MB/file; IndexedDB needed | Someday, no deadline |
| 32 | Note attachments under userdata sync: files are currently local (`attachments/` + index); under sync they will travel as files next to userdata.db | After 1.0 |
| 36 | ~~Bottom navigation.~~ Closed, see below. Was: two variants. **A** (advised): Home · Bible · Plan · Notes · Library — reading plan and infographics on their own tab (like the current "Schedule"); search — a field atop Home and Bible plus a button in reading; settings — a gear on Home. **B**: Today · Bible · Search · Notes · Library — "Today" (former Home) shows the plan day card, tap → full plan screen with infographics. Decide together with the reading-plans screen | Beta |
| 38 | ~~Source of the chronological order~~ — closed: yearly schedule sbr_U.pdf (column OCR), 366 days, 66-book coverage verified by a test | closed |
| 39 | ~~sherpa-onnx native-binary licenses~~ — closed: proceeding as planned in ADR 0017 (neural backend with sherpa-onnx and Piper packages) | closed |
| 40 | ~~Stress dictionary for biblical names and church words~~ — closed differently: auto-accents by the RUAccent nn_accent neural model (tract, `studybible-accent`, U+0301 after the stressed vowel) + `pronounce.dart` dictionary with priority; neural backend only (system backend would break char offsets); homographs unresolved (ADR 0017) | closed |
| 41 | Cloud TTS backend (Yandex SpeechKit / Azure): chapter cache on disk, network and keys only at the user's request | After Beta |
| 43 | Web search index lives one session: `fts` is added into an in-memory database in the background after module open (decision of 2026-10-12 — web modules ship without embedded `fts`). A persistent cross-session cache (IndexedDB/Cache API) and/or serving a ready `.idx.gz` lazily — not done; estimate the real indexing cost on a weak phone | After Beta |
| 44 | Custom text system `studybible-text` (ADR 0021 track, revised 2026-10-08): library — a ready shaper + own tier typesetter over word anchors + composer; Flutter shell via texture; the GPUI fork is cancelled. First step — stage 0 (token model and `\zaln`/MACULA/BCVWP links). Open: rasterizer variant (unified FreeType→atlas vs platform — decide in practice), texture embedding into Flutter (scroll, selection, a11y bridge), audio platforms under a thin host | After 1.0, when stage 0 begins |
| 42 | Custom voice (parallel task, postponed; plan — ROADMAP "Parallel tasks"): license of the base Russian Piper checkpoint for distributing a derived model; license of the training tools (GPL — does not affect the voice, verify); export compatibility with sherpa-onnx; user's hardware (microphone, NVIDIA or cloud). 2026-10-12: sherpa_onnx/onnxruntime cut from the 1.0 release for size (−73 MB) — the task is postponed together with the backend, return per ADR 0017 | When the user returns to it |

## Closed

- № 33. Footnotes: variant A by default — a superscript letter at the word, no space, unbreakable; variant B (dotted underline under the word, no mark) — when the module has binding text (`\fq`, `<catchWord>`). In "Reading" mode the marks are hidden; tap → card; hit area ≥ 44×44 (ADR 0015).
- № 37. Parallel places — per verse part: the converter preserves the mark's position and binding text (`\xq`/`\fq`, `\xo` with a `1:1a` letter); the "Parallel places" sheet groups by parts; links with a verse segment (related to № 13) (ADR 0015, ADR 0016).
- № 36. Bottom navigation: variant **A** — Home · Bible · Plan · Notes · Library. Variant **B** (Today · Bible · Search · Notes · Library) is recorded as an alternative (ADR 0015).
- № 34. Book tiles: stay saturated per ADR 0013; saturation lowered by 15–20 %, full book name — an option (≥ 11 sp). Tonal tiles rejected (ADR 0015).
- № 35. Module-format extension accepted on the condition of simple conversion and module creation (ADR 0016).
- The compact v1 schema revision was introduced before the freeze (ADR 0016 §15): `book_id`, a single verse text in `verses`, span text as slices `(verse, start, len)`, `v` markers only on empty verses. Old `.sb` files are rebuilt/migrated; no reader backward compatibility.
- Inline translation comparison: done (second translation dimmed under each verse).
- UI: Flutter + flutter_rust_bridge, chosen by the prototype (ADR 0013); the Slint pilot screen and writing to SixtyFPS are not needed.
- Canon: 66 books per the user's list; the rest marked "deuterocanonical", shown by default.
- Names, abbreviations and book order — per the module.
- Synodal: variant (a), the classic text where "Иегова" occurs.
- Copyright holder: "StudyBible contributors".
- UI languages: Russian and English.
- Web — at the very end; for now only the foundation and a wasm32 compile check.
- Minimum OS: Windows 10, macOS 12, Ubuntu 22.04, Android 8, iOS 15; memory — up to 150 MB. Windows 7/8 — no.
