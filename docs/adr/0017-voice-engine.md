# 0017. Voice engine: backends, neural synthesis, voice packages

**English** | [Русский](0017-voice-engine.ru.md)

Status: accepted.

Refines ADR 0010: offline neural synthesis and audio Bibles moved from
"after 1.0" to Beta (user decision 2026-10-06). The espeak-ng commitment
stands: GPL components do not enter the core.

## Context

Read-aloud goes through system synthesizers (`flutter_tts`). That is not
enough: voice quality varies per OS, the language engine/voice may be
missing, a pause inside a verse is impossible (resume = the verse from
the start), there is no per-word highlighting, and the format does not
provide for audio Bibles (the `marks` table is only groundwork).

## Decision

### Backend abstraction

`VoiceBackend` — a narrow interface in the UI layer (an adapter, not
domain): `available(language)`, `prepare`, `speak(text)` (await = the
phrase finished), `pause`/`resume`/`stop`, optional per-word mark stream
(char offsets). `ReaderTtsService` still owns the verse queue, the media
session and verse highlighting — only "who speaks" changes.

Backends:

- `system` — `flutter_tts` (all platforms including web);
- `neural` — `sherpa_onnx` (VITS/Piper models; native platforms: Windows,
  Linux, macOS, Android, iOS; unavailable on web — falls back to
  system);
- `file` (stub) — an audio Bible: chapter files + the module's `marks`
  table.

Why `sherpa_onnx` and not ONNX Runtime in the core: ready FFI binaries
for all platforms (Android included — `ort` on Android in Rust would
need separate linking), proven Piper-compatible models from k2-fsa,
CPU synthesis in hundreds of ms per verse. The package is not in the
core — it is an adapter next to `flutter_tts`.

### Voice packages

Directory `STUDYBIBLE_DATA/voices/<id>/` — outside the repository and
builds (models are 20–100+ MB, like modules). A package = an unpacked
`vits-piper-*` bundle from k2-fsa releases (contains `*.onnx`,
`tokens.txt`, `espeak-ng-data/`) or a raw Piper voice (`*.onnx` +
`*.onnx.json` — language/speakers read from the json). An optional
`voice.json` sets the name, BCP 47 language, speaker count.

Import — like modules: pick a folder or a `.tar.bz2`/`.zip` archive
(`file_picker` + `archive`), copy/unpack into `voices/`.

### Settings

`voiceEngine` = `auto | system | neural` (`auto` — neural if the module
language has an installed voice, else system). The voice is chosen per
language (`neuralVoices`: `ru → id`), speed is a separate slider. All
persisted where the theme is — JSON in userdata.

### Reading quality

- Pre-generation of the next verse during playback of the current
  (prefetch-1): transitions between verses without engine pause.
- Exact pause inside a verse on the neural backend (audioplayers
  pause/resume — the audio is already there; on system, resume = the
  verse from the start, as before).
- Per-word highlighting (option, off by default): on `system` — exact,
  from `flutter_tts` progress events (Android/iOS/macOS/web return word
  char-offsets); on `neural` — estimated by audio position proportional
  to word lengths; on `file` — exact from `marks`.
- Pronunciation dictionary (`pronounce.dart`, `neural` only):
  "word → word" substitutions with a U+0301 stress mark are applied to
  the synthesis text — the displayed verse is unchanged. The base set
  (Bible names, church vocabulary) is overridden by `pronounce.tsv` in
  the package folder. The dictionary is not applied to `system` — the
  progress char-offsets would refer to the substituted text and break
  highlighting.

### Language frontend: auto-stress and pauses

The main reason Russian Piper voices sound "unnatural" is that espeak-ng
stresses by rules and is often wrong. Verified: U+0301 after a stressed
vowel really changes the synthesis ("за́мок" ≠ "замо́к"), while "+" is
read aloud — we output only U+0301.

- Stress is placed by the RUAccent `nn_accent` neural model (MIT,
  char-level RoFormer, ~2 MB). It is installed once per language, not
  per translation — it works with any Russian text during reading.
- "ё" is restored via the RUAccent `yo_words` dictionary (a TSV asset
  `without_yo<TAB>with_yo`): "еще" → "ещё". Homographs (все/всё) are not
  resolved — imperfect but deliberate: contextual disambiguation at the
  cost of a second model does not pay off yet.
- The model is an app asset (`assets/voice/ru/`: `accent.onnx`,
  `vocab.txt`, `yo_words.tsv`, LICENSE). Inference — pure Rust on
  `tract` in the `studybible-accent` crate: a second copy of onnxruntime
  next to sherpa would conflict on DLLs, hence tract and not `ort`.
- Applied only to the `neural` backend: on `system` the progress
  char-offsets would break on substituted text, and system engines place
  stress themselves.
- Order in the synthesis text: `pronounce.dart` (pronunciation
  dictionary) → auto-stress. Per word: yo dictionary → stress lexicon →
  the neural net. The lexicon is also per-language, not per-translation:
  built by a tool (`apps/studybible-cli` `build_lexicon`) from the
  intersection of the RUAccent `accents.json.gz` dictionary with word
  forms of Russian translations from the module catalog (russyn,
  rstplus, ru_rob — 52 216 words, ~81 % coverage of encountered word
  forms); homographs (`omographs.json.gz`) are excluded — the neural net
  resolves them. It is used for any Russian text, not only verses of
  the modules it was built on.
- One stress per word: among STRESS_PRIMARY candidates with score
  ≥ 0.55 the position with the highest probability is taken, and only
  on a vowel. Single-syllable words (≤ 1 vowel) get no stress —
  otherwise speech is choppy ("же́", "на́д"); the exception is the
  "е→ё" yo_words substitution ("днём").
- Asset dictionaries are gzip-compressed (`yo_words.tsv.gz`,
  `lexicon.tsv.gz`), decompression — in the bridge (flate2), the crate
  receives strings. Total `assets/voice/ru/` assets: accent.onnx 2.3 MB,
  vocab.txt 0.1 KB, yo_words.tsv.gz 0.5 MB, lexicon.tsv.gz 0.35 MB
  (~3.1 MB total).
- A word already containing U+0301 or "ё" is not touched by the
  dictionaries or the net — the pronunciation dictionary has priority.
- Pauses: a verse is split into phrases at `, ; : . ! ?` — each is
  synthesized separately with silence inserted between them (comma
  120 ms, `; :` — 220 ms, `. ! ?` — 350 ms; constants in
  `lib/voice/phrases.dart`).

Choosing the system engine and voice (Android: `getEngines`/`setEngine`;
Windows: `getVoices`/`setVoice`) is moved to settings — the user can
install a quality engine (RuVoice on Silero, Google voices) and select
it, while the app weighs 0 MB of voice data.

A cloud backend (Yandex SpeechKit / Azure, caching chapters on disk) —
postponed, recorded in OPEN-QUESTIONS ("after Beta").

### Consequences and risks

- `sherpa_onnx` pulls onnxruntime binaries: APK/exe grow by tens of MB —
  the price of offline neural synthesis, accepted. The package was
  recently updated; we pin the version.
- espeak-ng (GPL) may end up inside the sherpa-onnx native library for
  Piper voices: `espeak-ng-data` in the packages is data, but espeak-ng
  code in `sherpa_onnx.so`/dll — the license check of native binaries
  was moved to OPEN-QUESTIONS before a public build with the neural
  backend.
- Ancient languages are still not voiced (ADR 0010) — the neural backend
  applies to the same languages as the system one.

### Status 2026-10-12 — neural backend cut from the 1.0 release

`sherpa_onnx` + `libonnxruntime` (~73 MB of native code ×3 ABI) removed:
the dependency was dropped in pubspec, `voice_neural_io.dart` deleted
(in git history), the `voice_neural.dart` shim exports a stub on all
platforms, the "neural" choice and the voice-package section removed
from settings. The system engine and auto-stress (tract, RUAccent)
remain. To bring it back: restore the file + dependency or build
sherpa-onnx in a TTS-only configuration (the ready AAR drags in ASR/VAD
and extra ~30–50 %). The own-voice decision (OPEN-QUESTIONS № 42) is
postponed together with the backend.
