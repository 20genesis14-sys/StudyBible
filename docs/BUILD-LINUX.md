# StudyBible — building and testing the Linux version (reproduction recipe)

**English** | [Русский](BUILD-LINUX.ru.md)

Test run date: 2026-10-08.

## 1. Environment used for building and testing

| Component | Value |
|---|---|
| OS | Ubuntu 22.04.5 LTS (jammy), kernel Linux 6.8.0-1061-aws x86_64 |
| Desktop | KDE Plasma, X11, 3200×2400 display (Wayland not required) |
| glibc | 2.35 |
| Flutter SDK | 3.47.6 (framework rev 5fc346839b, Dart 3.13.5) — same as the project |
| Rust | cargo/rustc 1.97.1 (needed for the native_toolchain_rust bridge) |
| clang | 14.0.0 (from the Ubuntu repository) |
| cmake | 3.22.1, ninja 1.10.1, pkg-config 0.29.2 |
| gtk | libgtk-3-dev 3.24.33 |
| gstreamer | libgstreamer1.0-dev 1.20.3, libgstreamer-plugins-base1.0-dev 1.20.1 (needed by audioplayers_linux) |
| other dev packages | libblkid-dev 2.37.2, liblzma-dev 5.2.5, libstdc++-12-dev 12.3.0 |
| python3 | 3.10 (for measurement scripts) |

## 2. Installing dependencies (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install -y cmake ninja-build clang pkg-config \
    libgtk-3-dev libblkid-dev liblzma-dev libstdc++-12-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
```

Also required: Flutter SDK 3.47.6 (unpacked, on PATH or called directly)
and an installed Rust toolchain (rustup, stable — we had 1.97.1): the
Flutter command itself pulls `native_toolchain_rust` and builds
`libstudybible_flutter_bridge.so` from the crate.

## 3. Data

```bash
export STUDYBIBLE_DATA=/path/to/StudyBible-data   # directory with modules/*.sb and userdata.db
```

Modules live in `$STUDYBIBLE_DATA/modules/*.sb` (russyn, int_en,
comm-henry, oshb were used).

## 4. Build

```bash
cd StudyBible/apps/studybible-flutter
STUDYBIBLE_DATA=/path/to/StudyBible-data flutter build linux --release
```

Built binary: `build/linux/x64/release/intermediates_do_not_run/studybible`.
Notes:
- `ninja install` in the project hard-installs into `/usr/local` (no prefix
  choice). To avoid touching the system — install the bundle into a
  directory:
  ```bash
  cd build/linux/x64/release
  DESTDIR=$HOME/sb_linux ninja install
  # produces $HOME/sb_linux/usr/local/{studybible, lib/, data/}
  ```

## 5. Run

```bash
cd $HOME/sb_linux/usr/local
DISPLAY=:0 STUDYBIBLE_DATA=/path/to/StudyBible-data LD_LIBRARY_PATH=lib ./studybible
```

Renderer — Impeller (OpenGL ES via GTK). The `dbind-WARNING AT-SPI`
warnings are harmless (no a11y bus).

For profile measurements instead of release:
```bash
cd StudyBible/apps/studybible-flutter
DISPLAY=:0 STUDYBIBLE_DATA=/path/to/StudyBible-data flutter run -d linux --profile
# output contains "A Dart VM Service ... at: http://127.0.0.1:PORT/<token>/"
```

## 6. How it was measured

- **Cold start**: launch the release binary, timer until the window
  appears (`wmctrl -l`), 3 runs → 0.64–0.65 s.
- **Scroll frames**: profile mode, connect to VM Service over WebSocket,
  subscribe to the `Timeline` stream, collect b/e event pairs `Frame`
  (script `tools/collect_frames.py <ws_url> <sec> <out>`). Scrolling —
  `xdotool click 5/4` at the window center (~1 wheel click / 350 ms),
  ~80 scroll events total.
- **Search**: search field → "милости" → Enter, time until the result
  list renders.
- **Weak CPU**: `cpulimit -p <pid> -l 30` (30 % of one core) — observing
  responsiveness.
- Window UI control: `wmctrl` (maximize), `xdotool` (clicks/scroll;
  real coordinates = screenshot coordinates × 3.125 on a 3200×2400
  display).

## 7. Results (duplicates REPORT_linux.md)

| Metric | Value | Limit |
|---|---|---|
| Cold start to window | 0.64–0.65 s | — |
| Reading Ps 118, scroll | frame p50 10.0 ms, p90 19.8, max 34.8 (~60 fps) | smoothness |
| Inline comparison (RUSSYN+OSHB) | p50 19.2 ms, p90 33.6, max 64.8 | ~30–50 fps on jumps |
| Search "милости" | instant | ≤200 ms |
| Weak CPU (30 % of a core) | UI loses responsiveness, no crashes | — |

All limits № 11/№ 22 met. Inline comparison is the heaviest view (same
reason: the whole chapter in one Column without virtualization); not
critical on desktop.
