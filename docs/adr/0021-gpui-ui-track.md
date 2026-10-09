# 0021. Our own text system `studybible-text` (post-1.0 track)

**English** | [Русский](0021-gpui-ui-track.ru.md)

Status: accepted as a development direction after 1.0 (user decision,
2026-10-12; **rewritten 2026-10-08** — the track was re-aimed from a
GPUI fork to the library path based on the `bible-text-scheme` analysis,
user decision). Implementation has not begun; Flutter remains the
production frontend on all platforms, removing the shell is optional
and postponed.

## Context

Flutter's limits for our task are confirmed by measurements: Windows
release cold start ~1.7–2.8 s with ~1.4–1.6 s for an empty app field,
APK ~80–126 MB, wasm web without a file system. Deeper — the model:
fine typography (text over text, ruby, interlinear, apparatus), custom
layers and complex scripts hit the engine's closed text pipeline. The
Rust core is already isolated and UI-agnostic — the cost of migration is
the cost of the frontend only.

Three equal principles of the future UI (fixed as acceptance criteria of
every stage):

1. **Highest text quality** on all platforms, in any form, in any
   language.
2. **Flawless speed and smoothness** of operation.
3. **Full customizability and extensibility**: layers, overlays,
   arbitrary compositions ("text over text") — standard render
   primitives.

## Key analysis finding (2026-10-08)

The product is not a toolkit but a **composer**. Tiered layout anchored
on words exists in no ready UI framework (GPUI, Parley, SkParagraph,
Slint, Qt — checked). A GPUI fork does not buy the main thing: its text
path is platform-based (Core Text / DirectWrite / cosmic-text), one
verse gets different glyph positions on different OSes, breaking
principle № 1; and writing Android/iOS-web support equals writing an
embedder — paying Flutter's price a second time. Conclusion: own the
token model, the tier composer and the compositor; take a ready-made
shaper; keep the shell replaceable.

## Decision

A Rust library **`studybible-text`** (working name) — five layers, three
of them ours:

| Layer | Implementation |
|---|---|
| Shaper | ready-made: HarfBuzz or HarfRust/rustybuzz — **we do not write our own shaper**: mark/mkmk, niqqud, te'amim, polytonic are already there. One shaper on all platforms = the condition of text parity; OS shapers are not used for scripture |
| **Tier composer** | **ours** — lays out tiers and aligns them by **word anchors**, not by the line. Interlinear, columns, apparatus, "text over text" — its job |
| Rasterizer | one and the same "glyph → image cache" path on desktop, mobile and web, otherwise the verse falls apart. **Open** (see below): option A — a single FreeType→atlas everywhere; option B — platform rasterization. Decision — when we get there in practice |
| Compositor | ours, thin: quads on GPU, only visible verses on screen, dirty regions (ideas borrowed from GPUI — without the repository) |
| Shell | replaceable: now **Flutter as a texture**; later, if weight and limits still hurt — a thin native host; web — the same crate in Wasm |

**The data model matters more than the render.** Interlinear is not
computed from a raw string: it needs stable token identifiers and links
"these original words = these translation words". Sources of links
exist: USFM (`\zaln`, `\w`), MACULA, the BCVWP scheme. Notes,
highlights and extensions reference a token ID, not a pixel and not a
string offset. Search and highlighting do not cut a word before
shaping: the word is shaped whole, a piece is painted — otherwise dots
and accents drift at the highlight boundary. Showing/hiding vowel
points — a different cache key, not manual glyph editing. Shape cache
key: text, font, OpenType features, scale bucket (the corpus is finite —
the shape is cached).

**Extensions** (future API, ADR 0020) call the composer in Rust — not
Flutter/GPUI/Slint widgets.

**Platform-layer scope when the shell is removed** (if we get to a thin
host): lifecycle, IME/keyboard, gestures, clipboard, accessibility
(AccessKit), audio/TTS (SAPI, AVSpeechSynthesizer, android.speech.tts,
speech-dispatcher, Web Speech API), audio-Bible playback. While the
shell is Flutter, these cost items are not ours.

## What we deliberately do not write

- Our own shaper — it would lose to HarfBuzz on te'amim and take years.
- A GPUI fork and GPUI Kit (previously accepted — **cancelled
  2026-10-08**): platform shaping diverges by OS; no tier/anchor model;
  mobile/web = our own embedder; GPUI Kit is desktop controls, does not
  typeset interlinear; maintenance is tied to the Zed cycle; versions
  change under Zed. From GPUI we take only two ideas: GPU quads and
  dirty regions.
- Replacing the text engine inside Slint — the paragraph model hinders
  arbitrary layout, GPL-3/commercial license.

## What we take ready-made

- HarfBuzz / HarfRust (rustybuzz) — shaping.
- Parley (Linebender) — only the plain paragraph: wrapping, BiDi,
  fallback, selection. It does not do tiers.
- AccessKit — a "glyph → token" map for the screen reader, design for it
  from the start.
- A glyph atlas is simpler than Vello for reading verses; Vello is an
  option for curves and zoom but requires compute shaders (old Android
  and part of the web fall out) — not the base.

## Stages

0. **Token and link model** (no rendering): token ID, original↔
   translation links from `\zaln`/`\w`/MACULA/BCVWP; notes already hang
   on IDs.
1. **Shape a word whole** + cache by the key above; golden tests start
   here.
2. **Tier composer** on top of ready runs: interlinear first, then
   columns and apparatus.
3. **Compositor**: draws runs, returns a "point → token" hit test.
4. **Embedding into Flutter as a texture**; extensions call the
   library. This is the stage of real complexity: scroll physics,
   selection, a11y bridging — checked before major investment.
5. **Golden verse tests** before the shell question. Minimum: Gen 1:1
   (niqqud+te'amim), Ps 119, polytonic John 1:1, a mixed verse with
   numbers.
6. **Vector export** with the same glyph positions (PDF, print) — the
   GPU atlas does not give this itself.
7. **Removing Flutter** — only if weight and limits still hurt after
   stage 4; a thin native host per platform.
8. **Web** — the same crate in Wasm (WebGPU/WebGL2); until ready, web
   stays on Flutter.

## Urgent requirements (keep in the model from the start)

- Selection, copying, read-aloud; on mobile — selection handles,
  magnifier, Hebrew/Greek IME (months of work — the reason not to drop
  Flutter early).
- Accessibility: the screen reader gets text ranges, not a picture.
- Dark theme: gamma correction for thin light strokes on a dark
  background.
- Zoom: scale buckets or GPU curves (a single-size atlas blurs).
- Scripts wider than Hebrew/Greek: Arabic, Syriac, Ge'ez — direction is
  designed into the model from the start.
- Font licenses (SBL Hebrew, SBL Greek) and text licenses.
- Two layout modes: reading and study — one engine, different policies.
- "Best look on this OS" and "the same verse everywhere" do not
  coincide: for scripture identical positions matter more; the app
  chrome may be system — the scripture may not.

## Alternatives (checked, rejected)

- **GPUI fork + GPUI Kit** — the previous decision, cancelled above.
- **Slint** — paragraph model, weak FemtoVG/software for text, GPL-3/
  commercial license.
- **Makepad** — its own text system of unverified quality on our
  scripts, small ecosystem.
- **rust-skia without Flutter** — the binary is big again (much of
  Flutter's size is Skia), interlinear is ours anyway.
- **Qt via a custom element** — the best ready text, but LGPL/
  commercial, a C++ boundary, a large binary.
- **iced/floem/egui/Dear ImGui** — no mobile or atlas-class text is
  weak.
- **Typst as a screen** — a static page, no hovering on morphology.
- **Vello as a mandatory base** — compute shaders narrow the reach.
- **Forking flutter_windows/engine** — does not pay off (see the start
  analysis).

## Risks (recorded)

- embedding a texture into Flutter: scroll physics, touch selection,
  a11y bridge — checked at stage 4 before investing in the shell;
- two live frontends for a transition period (Flutter + texture);
- audio/TTS on a thin host — our code on every OS if we drop the shell;
- team size: one composer over a ready shaper is one direction; a
  toolkit fork + four platforms would be several.

## Links

- ADR 0017 (voice engine): while the shell is Flutter, TTS lives there;
  on a thin host — OS APIs within the platform layer's scope.
- ADR 0018/0020: format v2 and the contribution registry do not depend
  on the UI; extensions target the composer, not widgets.
- `bible-text-scheme` (archive from the user, 2026-10-08) — the source
  of the revision: the token model, word anchors, tiers, stage order.
