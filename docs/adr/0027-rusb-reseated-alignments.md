# ADR 0027: rusb module + reseated Aquifer alignments

## Status

Accepted (2026-10-15).

## Context

`rsb-aquifer` (`sources/strongs/rsb-aquifer/`) contains two resources:

- `Russian-usfm.zip` — Russian Synodal Bible v1.1.0 (2025-12-01, CC0):
  a *modernized* Synodal edition (лицо/душою, bracketed editorial
  insertions `[Бог]`), not the classical 1876 text of `russyn`.
- `Russian-alignments.zip` — Clear-Bible/Alignments → RUSSYN word
  alignments (OT: WLCM, NT: SBLGNT; CC BY-SA 4.0; `process: "manual"`,
  234,908 records covering all 66 books).

The alignments looked like a manually-verified gold source that could
replace our noisy RSTS→SequenceMatcher projection for a modern-Synodal
layer, and feed `corpus-ru` with hand-checked evidence.

## Findings

Direct conversion (record target-position → w1 index, source mid →
dStrong via `step-orig`) produced a layer with only **47.6 % agreement**
with the `russyn` projection on identical verses. Diagnosis:

- Target positions are *honest* (their own `targets/RUSSYN/*.tsv`
  confirms the token stream: words + punctuation as tokens, `—`
  excluded, hyphenated words merged; claimed word matches the token at
  the claimed position in 99.997 % of records).
- Source mids resolve correctly in `step-orig`.
- But the *pairing* is semantically wrong in verses with reordered
  words: each source group is bound ~1–3 positions right of its true
  partner (Быт 1:2 `тьма`←בֹּהוּ, Ин 3:16 `отдал`←κόσμον,
  Мф 1:1 `Давидова`←χριστοῦ). The same content exists upstream at
  `Clear-Bible/Alignments` — not an Aquifer export bug.
- The pattern is characteristic of unverified *automatic* alignment
  labeled `manual`.

## Decision

1. `rusb.sb` (66 books, `rsc`, CC0) is a separate module — the
   modernized Synodal edition alongside classical `russyn`.
2. `rusb-strongs.sb` is built by **reseat**
   (`tools/strongs/pipeline/reseat_rusb_layer.py`): trust the
   source-side groupings (mid→dStrong) and re-assign each record's
   target word among the verse's w1 tokens via `priors_ru`
   (lex 10/stem 6/func 5 − distance penalty, greedy 1:1 assignment).
   Records with no lexical candidate are **dropped** (the raw claimed
   position is a ~42 % coin flip — worse than a gap).
3. Result: 194,512 links; **96.44 % agreement** with `russyn-strongs`
   on identical verses — the claimed positions are treated as weak
   evidence, never truth.
4. The layer keeps `source='rsb-aq-reseat'`, CC BY-SA 4.0 attribution
   for the Clear-Bible data; `rusb` text stays CC0.
5. `corpus-ru` is **not** fed from this layer yet — the reseated layer
   is a valid annotation layer but its Synodal-column evidence still
   needs an edition label (`rusb` ≠ `russyn`) before statistics.

## Consequences

- + a verified-quality Strong's layer for the modernized Synodal text
  (96.4 % agreement with the vetted `russyn` projection).
- − coverage is lower than `russyn` (194k vs 570k links): Aquifer only
  marks genuinely-aligned words; added/aux fill can be added later via
  the same `_fill_untagged` pass if needed.
- The raw Aquifer pairings remain a documented caution: "manual" labels
  in third-party alignment data must be spot-verified before use.
- `alignments/*.alignment.json` conversion code stays as research
  tooling (`build_rusb_layer.py` produces the broken direct layer;
  `reseat_rusb_layer.py` produces the deployed one).
