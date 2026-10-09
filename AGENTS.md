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
