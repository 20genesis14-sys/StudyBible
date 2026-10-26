# 0030. Chapter render cache and chrome notifiers

**English** | [Русский](0030-chapter-render-cache.ru.md)

Status: accepted (2026-10-18).

## Context

The reading screen is one `State` (`_ReadingScreenState`, five `part`
files). Every `setState` rebuilds the whole chapter: `TextSpan` /
`WidgetSpan` / gesture recognizers are recreated in `_buildChapter` on
each pass. Dynamic state is baked into the spans — the selected verse,
the read-aloud verse and the read-aloud *word* (`_selectedVerse`,
`_ttsVerse`, `_ttsWord`); the word tick arrives several times a second,
so a long chapter in "Study" mode with an interlinear costs a full
rebuild of thousands of spans per spoken word. Recognizer garbage is
collected manually (`_rotateTapRecognizers`); the `_lineCache` covers
only second lines (compare/interlinear), and its entries could hold
recognizers the rotation had already disposed.

Three roadmap tracks are blocked by this: 120 fps on long chapters
(Alpha requirement), multi-pane workspaces (ADR 0014 — panes must not
rebuild each other), and the custom text system (ADR 0021 — its tier
typesetter needs "text = cached function of state").

Key observation: at any moment the selected/TTS state touches only one
or two verses. Everything else is cacheable.

## Decision

1. **Chapter line cache** (`ChapterLineCache`, `lib/reader/line_cache.dart`):
   built widgets are cached per key — verse lines `L:verse`, paragraph
   blocks `B:block`, interleaved rows `I:verse`, second lines
   `S:module:verse` and interlinear pair lines `P:…` (as before). Peek
   pages use the `p|` prefix. The cache clears when the render
   signature changes (`_syncLineCache`: module, chapter, layout,
   display settings, palette, lexicon, conversions, interlinear mode)
   and when user records reload (`_loadVerseEntries`).
2. **Dynamic exclusion**: a line is *dynamic* when it contains the
   selected verse or the read-aloud verse. Dynamic lines are built past
   the cache; their stale entries are evicted while they stay active.
   A deactivated line rebuilds once (clean styling) and re-enters the
   cache. In paragraph mode a *block* is dynamic when it contains an
   active verse; a rebuilt block's span cursor is seeded with the
   active verse's counters from the preceding blocks (verses continue
   across block boundaries in poetry; `_hlFrags`/TTS word offsets must
   stay continuous).
3. **Recognizer ownership**: recognizers created while building a
   cached line belong to the cache entry and are disposed on eviction,
   signature clear and screen dispose (deferred to post-frame — the
   widget may still be in the previous frame). Uncached builders keep
   the existing per-frame rotation. This also fixes a latent bug of the
   old `_lineCache`: second-line entries held recognizers the rotation
   had already disposed.
4. **Chrome on notifiers**: bar visibility, the floating search field
   and the notes panel move to `ValueNotifier`s with local
   `ListenableBuilder`s. Toggling chrome no longer rebuilds the text.
   The desktop notes panel gets a state-owned `ScrollController` (was
   created in `build()` — reset scroll and leak on every rebuild).
5. **TTS tick routing**: the word tick updates only the active line
   (a notifier the dynamic line listens to); verse ticks stay
   screen-level (cheap after step 1). Media/player state keeps its own
   callback.
6. **Pane compare list, not settings**: the compare-module list restored
   from a position snapshot goes to a screen field (`_interleavedOverride`),
   not into `Settings.interleavedModules` — navigation no longer writes
   a global setting on every back/forward step.

## Consequences

- Full-screen `setState` cost drops to chrome plus one or two fresh
  lines; a word tick rebuilds one line.
- Cached lines survive selection/TTS changes; taps and long-presses of
  cached lines keep working for the entry's lifetime.
- Book-feed caching (`_bookBlocks`) is deferred — the feed still
  rebuilds per `setState` (follow-up in this ADR's track).
- The line cache holds widgets, not RenderObjects — memory is a few MB
  on an interlinear chapter, freed on signature change.
- The seed walker for dynamic blocks mirrors the counter rules of
  `_spanOf`; both sides must change together.

## Update 2026-10-18 — book feed and measurements

1. **Book feed cached** (`_bookBlocks`, same-day follow-up): keys
   `bk:<chapter>:B:<block>` (`p|` prefix for peek). The verse-number
   color depends on `_selectedVerse` without a chapter gate, so a block
   containing the selected/read-aloud verse is conservatively dynamic
   in *every* chapter of the feed; TTS/selection painting itself is
   gated to `_ch`, and only that chapter gets a seeded cursor.
   `_bookBlocks` bypasses `_buildChapter`, so it now calls
   `_syncLineCache` itself — without it the feed's cache would never
   invalidate on settings changes.
2. **Diagnostics and a kill switch** (`line_cache.dart`): instance and
   static hit/miss counters (`ChapterLineCache.totalHits/totalMisses`)
   and the compile-time flag `STUDYBIBLE_NO_RENDER_CACHE` — with it
   every line takes the dynamic path, reproducing the pre-ADR behavior
   for honest before/after runs.
3. **Bench** (`test/render_bench_test.dart`): the real `ReadingScreen`
   on engbsb PSA 119 (176 verses, "Study" mode), cold build + 20 hot
   rebuilds (settings notifications) + book-feed smoke. Wall-clock in
   the test environment (no raster) — only ON/OFF ratios are
   meaningful:

   | Scenario (PSA 119, study) | cache ON | cache OFF | delta |
   |---|---|---|---|
   | cold chapter build | 117 ms | 118 ms | no first-build penalty |
   | hot screen rebuild, avg (chapter) | 19.4 ms | 22.3 ms | ~12 % |
   | hot screen rebuild, avg (book feed) | 14.8 ms | 20.0 ms | ~26 % |
   | cache after 20 hot rebuilds | 3 520 hits / 0 misses | 0 / 0 | 100 % hit rate |

   On a device the gap should grow: widget/recognizer construction
   competes with real raster work there. The per-word-tick win is not
   directly visible in these numbers — a word tick rebuilds one wrapped
   line (notifier), while the bench measures screen-level rebuilds,
   which is what every tick cost before the change.
