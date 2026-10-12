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
- Commit after each completed step; broad changes — per directory
  (`docs/`, root, `data/`, `apps/`…), so GitHub shows a readable
  message per path.
- CI is the local script `scripts/ci.ps1`.
- Navigation in `ReadingScreen`: bare `Navigator.pop`/`maybePop`/
  `pushReplacement` is forbidden — `PopScope(canPop: false)` swallows
  them silently. All intentional route exits go through `_popRoute()`.
  Two back semantics are named and kept separate: `_stackBack()`
  (position history — system gesture, Alt+←/→, mouse X1/X2) and
  `_hierarchyBack()` (strictly up: chapter → chapter grid → book grid —
  the AppBar arrow only).
- Published documents are bilingual: English `X.md` is primary,
  Russian `X.ru.md` is its mirror (except `docs/ROADMAP.md` — Russian,
  local-only).

## Source of decisions

`docs/DECISIONS.md` is the source of truth; the full document map lives
in `docs/SPEC.md` — do not duplicate it here.

## Verification

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ci.ps1
```

Steps: fmt, clippy (`-D warnings`), test, `cargo check` of the core for
`wasm32-unknown-unknown`, `cargo deny check` — prerequisites and build
variables are in `docs/ENVIRONMENT.md`.
APK builds — only arm64-v8a (the user tests on his device):
`flutter build apk --release --target-platform android-arm64`.
After building an APK check the native libraries' target API:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-apk-api.ps1`
(the bridge must not exceed minSdk).
In the core, clippy forbids `std::fs` and `std::thread::sleep`
(`crates/studybible-core/clippy.toml`).

Flutter changes (app dir `apps/studybible-flutter`):
`D:\StudyBible-tools\flutter\bin\flutter analyze`; bridge tests need
`STUDYBIBLE_DATA=D:\StudyBible-data`.

## Data

External texts (translations, modules) live outside the repo in
`STUDYBIBLE_DATA` (`D:\StudyBible-data`) — never commit them.
Fetch/verify commands and the `data/` layout: `docs/ENVIRONMENT.md`.

## Environment

Toolchain paths and machine quirks — `docs/ENVIRONMENT.md`.

## WSL builds — permanent rule

All Linux-side work (F-Droid builds/verifies, `flutter build linux`,
heavy git/file operations) runs **inside the WSL ext4 filesystem**,
never over `/mnt/d` (9p — tens of times slower on metadata):

- Checkout and build from `~/StudyBible` in the Ubuntu distro
  (origin `file:///mnt/d/StudyBible`; sync via `git fetch` + checkout).
  `D:\StudyBible` remains the master copy.
- F-Droid workdir is `/home/vagrant/fdroiddata` (canonical path,
  mirrors the buildserver — required for `fdroid verify` parity).
- `D:\StudyBible-fdroid` is an outdated copy — do not build from it.
- `/mnt/d` is used only for inputs and exporting artifacts
  (e.g. `D:\StudyBible-dist`).
- Full layout and `fdroid verify` specifics: `docs/ENVIRONMENT.md`
  («WSL layout»).
