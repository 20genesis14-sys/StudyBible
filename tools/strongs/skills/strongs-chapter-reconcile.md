---
name: strongs-chapter-reconcile
description: Reconcile chapter-wide Strong's alignments for consistency of repeated terms and proper names, and emit chapter receipt JSON
---

# `strongs-chapter-reconcile` — Step 7c of the Strong's Layer Pipeline (ADR 0025)

## Input
- All verse alignments of a chapter (`<BOOK>.<ch>`) and review scores.

## Reconciliation Tasks
1. **Intra-chapter lexical consistency:** If the same target content word (e.g. a recurring noun or proper name) appears multiple times in the chapter and has a high-confidence (`conf >= 9`) `dStrong` in one verse, propagate that `dStrong` to ambiguous occurrences of the same word in the same chapter when supported by the verse's candidates.
2. **Receipt generation:** Write `STUDYBIBLE_DATA/work/strongs/runs/<target>/<BOOK>.<ch>.json` containing:
   - `model`, `rules_version`, `rules_hash`, `date`
   - `stats` (`total_words`, `conf_hist`, `roles_hist`, `unresolved`)
   - `verses` (`word` -> `ref`, `strong`, `conf`, `flags`, `source`)
