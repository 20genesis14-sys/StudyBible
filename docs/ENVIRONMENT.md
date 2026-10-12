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
  This is not cosmetic: the user profile path `C:\Users\Ольга` contains
  Cyrillic, and Gradle-invoked `ninja -C` fails to `chdir` into it —
  plugin CMake steps (e.g. `jni`) die with
  `ninja: fatal: chdir ... No such file or directory`. Without
  `PUB_CACHE` the build silently falls back to
  `C:\Users\Ольга\AppData\Local\Pub\Cache` and hits exactly that.
  Emergency workaround if the env var is missing: junction
  `mklink /J C:\pcache <default pub cache>` and `PUB_CACHE=C:\pcache`.
- CI prerequisites: `rustup target add wasm32-unknown-unknown`,
  `cargo install cargo-deny --locked`.

## WSL layout (F-Droid / Linux builds)

The `Ubuntu` distro lives on `D:` (`D:\WSL\Ubuntu`, ext4.vhdx) — everything
inside `~` is physically on `D:` but accessed as native ext4, avoiding the
`/mnt/d` (9p/DrvFs) penalty on metadata-heavy work
(`git status` on the repo: ~3.4 s via `/mnt/d` vs ~0.1 s in `~`).

- `~/StudyBible` — second checkout of the repo in ext4;
  `origin = file:///mnt/d/StudyBible`, sync via `git fetch` + checkout.
  `D:\StudyBible` stays the master copy for Windows tools.
- `/home/vagrant/fdroiddata` — **canonical** F-Droid workdir (mirrors the
  buildserver layout `/home/vagrant/fdroiddata/build/<appid>` so APK paths
  match for `fdroid verify`). Builds/verifies run here as user `gedeon`.
- `~/fdroid-fork` — fdroiddata fork for the upstream MR (GitHub-source
  recipe with `binary:` + `AllowedAPKSigningKeys`).
- `~/flutter` — Flutter SDK checkout pinned at `5fc346839b` (3.47.6),
  used by F-Droid builds (srclib) and Linux builds.
- `~/Android/Sdk` — Android SDK + NDK 28.2 inside ext4; rustup 1.99.0 in
  `~/.cargo`.
- `D:\StudyBible-fdroid` — **outdated** copy of an old local-repo
  fdroiddata; kept as backup, do not build from it.
- `fdroid verify`: downloads go to `f-droid.org` by default; for local
  comparison copy reference APKs to `tmp/<name>.apk` and run
  `fdroid verify --reuse-remote-apk`.
- Rule of thumb: sources, build trees and caches inside ext4 (`~` or
  `/home/vagrant`); `/mnt/d` only for inputs and exported artifacts.

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
