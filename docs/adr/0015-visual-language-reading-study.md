# 0015. Visual language "book and vermilion", "Reading" and "Study" modes

**English** | [Русский](0015-visual-language-reading-study.ru.md)

Status: accepted (2026-10-05), per the local design-review mockups.

## Context

The prototype is practical but looks like stock Material 3. The app has
two audiences: readers and studiers. Study markers (Strong's
underlines, footnote and cross-reference markers) get in the way of
plain reading.

## Decision

- Visual language: warm paper, ink, one accent — vermilion (red).
  The chapter number is a vermilion initial; verse numbers — small
  superscript. Vermilion is only for navigation and the active state.
- A single "Reading / Study" toggle in the top bar.
  "Reading": clean text, no markers. "Study": verse per line, a dot in
  the margin — cross-references, a letter after a word — a footnote, the
  rest per the layers.
- The "Layers" sheet: footnotes, cross-references, Strong's numbers,
  second translation, interlinear — toggles. This is the UI of the Layer
  model (ADR 0014).
- Bottom reading bar: 4 monochrome buttons — Translation · Layers ·
  Listen · More. A background gradient under the bar instead of blur.
- Top bar: tapping "Book Ch. ▾" — quick navigation (book → chapter);
  tapping the translation name — the translation list. "More": history,
  go to verse, layout, font and theme, chapter bookmark,
  copy/share, reading settings.
- Bottom navigation, variant A (accepted): Home · Bible · Plan ·
  Records · Library. Search — a field at the top of Home and Bible, a
  button in reading; settings — a gear on Home. Reasons: plans have
  several screens (picker, calendar, statistics); the "Schedule" tab was
  already familiar; search is present on all main screens.
- Alternative B (not accepted, kept): Today · Bible · Search · Records ·
  Library. "Today" is Home with the plan-day card; a tap opens the full
  plan screen. Return to B if the "Plan" tab is little used.
- The "Plan" screen: progress ring, day streak, week, "Today" with
  checkmarks, a "Read map" over 66 books, other plans (mockups 05, 06).
  First-version plans: "Chronological" and "Gospels"; a plan is JSON
  data.
- Book grid: the ADR 0013 layout and saturated tiles stay; saturation
  lowered by 15–20 %; full book name — an option (≥ 11 sp). Tonal tiles
  (mockup 3) rejected: read worse.
- Footnotes (2026-10-05): variant A by default — a superscript letter at
  the word, no space, non-breaking; variant B — a dotted underline on
  the word with no sign, if the module has anchor text (`\fq`). Variants
  A′ (per the language rule at the end of the phrase) and B (sign only
  in the margin) rejected. Tap → a card; hit area ≥ 44×44.
- Cross-references — per verse parts: a ° sign after the phrase, a
  "Cross-references" sheet by parts (`Mt 1:1a · "…"`). No anchor — to
  the whole verse.
- Sepia and the "original above gloss" interlinear — as in mockup 4.

## Comparison via versification and superscriptions (questions 8–10, 2026-10-07)

- Mechanics: the core's `convertVerse` maps a verse between module
  versifications via org (`Versification::convert`); on native platforms
  — the FRB bridge `api::convert_verse`, on web — a Dart port of the
  parser (`lib/vrs_parser.dart`) over the same `.vrs` from the
  `assets/data/vrs/` assets (parity checked by tests). Identical
  versifications — a shortcut without the bridge; the result is cached
  per chapter (`_conv` in the reading screen).
- Inline comparison: under the main verse — all corresponding verses of
  the second translation in a row; the second verse number is shown as a
  small muted "chapter:verse" prefix when it differs from the main one
  (rsc Ps 89:2 → eng "90:1"). An empty correspondence — "…". The
  interlinear (original words) is converted by the same reference.
- Column comparison: second-column lines follow the main column's
  verses with the second versification's numbers; chapters pointed to by
  correspondences load lazily; second-chapter verses without a
  correspondence are appended at the end with their own numbers.
- The "Compare" screen: the source coordinate is in the main module's
  versification (`fromVrs` parameter); for each translation — a
  conversion, multiple correspondences are listed with "chapter:verse",
  a tap navigates to the first coordinate (chapter and book may differ).
  An empty correspondence — "not in this translation".
- Footnote/parallel cards: references in the data are in the source
  module's versification; text from xrefModule is taken by the converted
  coordinates (each verse of the range), a tap navigates to the
  converted place in xrefModule.
- Superscription (verse 0, variant A): a separate line above the first
  verse labeled "superscription"; each comparison part has its own
  verse-0 text (the second one via conversion — verse 0 participates in
  `.vrs` mappings); for a translation without verse 0 — a dash. If the
  superscription is merged into verse 1 of the target module, it counts
  as "empty" — no deduplication is done.
- Data: three upstream `vul.vrs` typos fixed locally (comment
  "# fixed by StudyBible"): `DAG 3:52-23` → `3:52-53`, `SUS 1:63` →
  `1:1-63`, `BEL 1:42` → `1:1-42`.

## Consequences

Supersedes the ADR 0013 "bottom menu" item and the "×" marker
presentation. Book-group colors per ADR 0013 remain, with the saturation
adjustment.
