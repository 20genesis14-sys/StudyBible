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

Toolchain paths and machine quirks — `docs/ENVIRONMENT.md`.
