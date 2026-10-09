# Environment

**English** | [Русский](ENVIRONMENT-ru.md)

Toolchain paths and local quirks of the working machine.

## Layout

- The whole project lives on drive `D:`: repo `D:\StudyBible`, data
  `D:\StudyBible-data`, tools `D:\StudyBible-tools`.
- Windows; Rust 1.99.0 (cargo, rustup installed).
- Flutter SDK 3.47.6 — `D:\StudyBible-tools\flutter` (not in PATH, call
  `D:\StudyBible-tools\flutter\bin\flutter`); Android SDK —
  `D:\StudyBible-tools\android-sdk`.
- Python — `C:\Users\Ольга\AppData\Local\Programs\Python\Python311\python.exe`
  (the `python` command does not work — Microsoft Store alias).
- Git 2.55.0 (`C:\Program Files\Git\cmd\git.exe`). Already-open shells may
  have a stale PATH — re-read it from the registry or open a new shell.

## Quirks

- Default shell (bash) — WSL Git Bash; run Windows builds and checks in
  PowerShell.
- Save `.ps1` scripts with Cyrillic as UTF-8 with BOM: Windows PowerShell 5
  otherwise reads them as ANSI.
- Build Flutter with isolated caches:
  `PUB_CACHE=D:\StudyBible-tools\pub-cache`,
  `GRADLE_USER_HOME=D:\StudyBible-tools\gradle-home`.
- CI prerequisites: `rustup target add wasm32-unknown-unknown`,
  `cargo install cargo-deny --locked`.

## External data (`STUDYBIBLE_DATA`)

`D:\StudyBible-data` (`C:\StudyBible-data` is a leftover directory).
The directory is deliberately outside the repository: Bible texts must
not be published on GitHub together with the code.

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1        # download and verify SHA-256
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1 -Pin   # re-pin hashes after a source update
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-data.ps1        # verify contents
```

In the repo: `data/canon/canon-66-knig.md` — the original canon list
from the user; `data/profiles/` — book and deuterocanonical profiles;
`data/versification/` — Paratext files (MIT); `data/tests/` — test
fixtures. Checks — `crates/studybible-convert/tests/stage0_fixtures.rs`;
text-based checks are skipped (SKIPPED) when the data directory is absent.
