# AGENTS.md

## Working rules

- Two local repositories: `D:\StudyBible` (working, candidate for
  GitHub) and `D:\StudyBible-priv` (private copy).
  **Never touch `D:\StudyBible-priv`** — do not read, write,
  or run commands there — except on an explicit user command for a
  specific action.

- All planned changes are written to documents first, then made in code.
- On any change to decisions, architecture or scope, update:
  - `docs/SPEC.md` and the relevant `docs/` section;
  - `docs/ROADMAP.md` (local only — never push it) and `docs/OPEN-QUESTIONS.md`;
  - a new or changed ADR in `docs/adr/`;
  - `docs/DECISIONS.md` — the source of truth for decisions.
- Do not start coding without an explicit user command.
- `unsafe` is allowed when justified; every block needs a `// SAFETY:` comment (clippy checks).
- Commit after each completed step. Broad changes are committed per
  directory (`docs/`, root files, `data/`, `apps/`… separately) —
  GitHub shows each path the message of the last commit that touched
  it, and one sweeping commit looks untidy across half the repo.
- CI is the local script `scripts/ci.ps1`.
- Language of published documents — English.

## Source of decisions

- `docs/DECISIONS.md` — current decisions; `docs/SPEC.md` — table of contents;
  `docs/adr/` — rationale; `docs/ROADMAP.md` (local only) — work progress;
  `docs/OPEN-QUESTIONS.md` — open questions.
- `C:\Users\Ольга\Documents\Принятые решения v2.txt` — the original version,
  migrated into `docs/DECISIONS.md`, no longer updated.

## Verification

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ci.ps1
```

Steps: fmt, clippy (`-D warnings`), test, `cargo check` of the core for
`wasm32-unknown-unknown`, `cargo deny check`.
Required: `rustup target add wasm32-unknown-unknown`, `cargo install cargo-deny --locked`.
After building an APK check the native libraries' target API:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-apk-api.ps1`
(the bridge must not exceed minSdk; build with
`PUB_CACHE=D:\StudyBible-tools\pub-cache` and `GRADLE_USER_HOME=D:\StudyBible-tools\gradle-home`).
In the core, clippy forbids `std::fs` and `std::thread::sleep`
(`crates/studybible-core/clippy.toml`).

## Data

External texts live outside the repository, in `STUDYBIBLE_DATA`
(user: `D:\StudyBible-data`; `C:\StudyBible-data` is a leftover directory).
For Dart bridge tests set it explicitly: `STUDYBIBLE_DATA=D:\StudyBible-data`.
The directory is deliberately outside the repository: Bible texts must not
be published on GitHub together with the code.

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1        # download and verify SHA-256
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1 -Pin   # re-pin hashes after a source update
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-data.ps1        # verify contents
```

`data/canon/canon-66-knig.md` — the original canon list from the user.
`data/profiles/` — book and deuterocanonical profiles; `data/versification/` —
Paratext files (MIT); `data/tests/` — test fixtures. Checks —
`crates/studybible-convert/tests/stage0_fixtures.rs`; text-based checks are
skipped (SKIPPED) when the data directory is absent.

## Environment

- Save `.ps1` scripts with Cyrillic as UTF-8 with BOM: Windows PowerShell 5
  otherwise reads them as ANSI.

- Default shell (bash) — WSL Ubuntu; run Windows builds and checks in PowerShell.

- The whole project lives on drive `D:`: repo `D:\StudyBible`, data
  `D:\StudyBible-data`, tools `D:\StudyBible-tools`.
- Windows; Rust 1.99.0 (cargo, rustup installed).
- Flutter SDK 3.47.6 — `D:\StudyBible-tools\flutter` (not in PATH, call
  `D:\StudyBible-tools\flutter\bin\flutter`); Android SDK — `D:\StudyBible-tools\android-sdk`.
- Python — `C:\Users\Ольга\AppData\Local\Programs\Python\Python311\python.exe`
  (the `python` command does not work — Microsoft Store alias).
- Git 2.55.0 (`C:\Program Files\Git\cmd\git.exe`). Already-open shells may have
  a stale PATH — re-read it from the registry or open a new shell.
