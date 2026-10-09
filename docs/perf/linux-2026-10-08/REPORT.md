# Report: building and testing the Linux version of StudyBible

**English** | [Русский](REPORT.ru.md)

Date: 2026-10-08. Test bench: Devin VM (KDE/Plasma, X11, 3200×2400
display), release build GTK + Impeller (OpenGL ES). Profile run —
`flutter run --profile -d linux`, VM Service, frame capture via
collect_frames.py. Data — 5 modules from STUDYBIBLE_DATA (.sb).

## 1. Build

`flutter build linux --release` — required packages:
`cmake ninja-build clang pkg-config libgtk-3-dev libblkid-dev liblzma-dev libstdc++-12-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev` (audioplayers_linux requires gstreamer).

Nuance: `ninja install` tries to install into `/usr/local` — worked around
with `DESTDIR=...` (binary + lib/*.so + data/flutter_assets). Launch:
`LD_LIBRARY_PATH=lib` + `STUDYBIBLE_DATA=...` — starts on Impeller (GL
backend), the Rust bridge and SQLite are native.

## 2. Functional run

| Scenario | Result |
|---|---|
| Launch, home screen, tabs | OK |
| Book grid → Ps → chapter 118 | OK, instantly |
| Chapter reading, scroll | OK |
| Inline comparison (RUSSYN + OSHB, Hebrew) | OK — Hebrew second lines render correctly (RTL) |
| Search "милости" | OK, results immediately (native FTS) |
| Position/history (userdata.db) | OK — after restart "Continue reading: Ps 118" |

Remarks:
- One `userdata.db locked` in the log at a first-start race (two
  instances on one DB) — does not block.
- dbind/AT-SPI warning — the test VM lacks the accessibility bus; a
  normal distro has it.
- Observation: OSHB works as a *second* module; the Greek NT without
  Ps 118 correctly shows "chapter not found".

## 3. Performance metrics

Cold start (release, window on screen): **0.64–0.65 s** (3 runs).

Scrolling Ps 118 (profile, VM Service, UI+raster frames):

| Scenario | p50 | p90 | max | rating |
|---|---|---|---|---|
| Reading | 10.0 ms | 19.8 | 34.8 | ~60 fps, smooth |
| Inline comparison (RUSSYN+OSHB) | 19.2 ms | 33.6 | 64.8 | ~30–50 fps on scroll jumps |

Module search: instant (<1 s to the full result list).

"Weak CPU" experiment (cpulimit 30 % of one core): the UI visibly lagged
— clicks took seconds; lifting the limit instantly restored
responsiveness. No exact capacity for extrapolation, but the desktop
build has a large reserve.

## 4. Conclusions

- The Linux build is fully working and the fastest of those tested:
  start 0.65 s, reading ~60 fps, instant search — all limits
  № 11/№ 22 met.
- Inline comparison is again the heaviest view (×2 vs reading: p50 19 ms,
  tails up to 65 ms) — same reason: the whole chapter in one Column
  without virtualization. Package B remains relevant, but the reserve on
  desktop hardware is so large that jank is visible only on aggressive
  scrolling.
- For the installer: the install target puts files in `/usr/local`
  without a prefix choice — distribution (AppImage/deb) will need
  DESTDIR or an FHS layout.
