# StudyBible

**English** | [Русский](README.ru.md)

A cross-platform app for reading and studying the Bible.

Two equally important goals:

1. **Reading** — a simple, convenient, fast app.
2. **Study** — cross-references, Strong's lexicon, translation comparison,
   interlinear, original languages, commentaries.

The core is written in Rust using a ports-and-adapters design; the UI is
Flutter (Android, Windows, macOS, Linux, web). User data stays on the user's
device only.

Bible texts are not part of this repository. They live in a separate
`STUDYBIBLE_DATA` directory (next to the repo, `..\StudyBible-data` by default)
so that publishing the code does not publish the Bibles along with it.

## System requirements

| Platform | Minimum |
|---|---|
| Android | Android 8.0 (API 26); APKs built for armeabi-v7a, arm64-v8a and x86_64 |
| Windows | Windows 10 (64-bit) or newer |
| Web | A modern browser with WebAssembly (Chrome, Firefox, Safari, Edge) |
| Linux / macOS / iOS | Build from source (Flutter 3.47+, Rust 1.99+) |

Status: 1.0.1. Documentation — [docs/SPEC.md](docs/SPEC.md),
open questions — [docs/OPEN-QUESTIONS.md](docs/OPEN-QUESTIONS.md),
changes — [CHANGELOG.md](CHANGELOG.md).

## Structure

| Path | Purpose |
|---|---|
| `crates/studybible-core` | Core: domain and ports |
| `crates/studybible-convert` | Module format converters (library) |
| `crates/studybible-store` | SQLite module, search, user data |
| `crates/studybible-accent` | Lexicon and stress marks for TTS |
| `apps/studybible-cli` | Console frontend (`studybible`) |
| `apps/studybible-flutter` | The app (Flutter + Rust bridge) |
| `data/` | Canon, book profiles, versifications, test fixtures |
| `docs/` | Specification, decisions (DECISIONS), ADRs, plans |

## Building

Console and core:

```
cargo build
cargo test
cargo run -p studybible-cli
```

The app: `apps/studybible-flutter`, a regular `flutter build`
(per-platform instructions are in `docs/`).

## License

The code is distributed under your choice of:

- MIT ([LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

Bible texts and other data are distributed separately; each module carries
its own license and attribution.
