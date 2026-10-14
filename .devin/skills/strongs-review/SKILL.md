---
name: strongs-review
description: Independently verify verse Strong's alignment or lexicon translation and assign a calibrated confidence score (0-10)
---

# `strongs-review` — Step 7b of the Strong's Layer Pipeline (ADR 0025)

## Input
- Verse words (`w1`), `step-orig.sb` candidates, and proposed `links`.

## Evaluation Criteria (§4.1 HANDOFF)
- **Hard check (cap `conf <= 4` if violated):**
  - Every `dstrong` code exists in `strongs-step.sb`.
  - Every `ref` (`wid`) belongs to the verse in `step-orig.sb`.
- **Polysemy check (cap `conf <= 7` if unresolved):**
  - If two different `dStrong` sub-senses of the same classic root appear in the verse and the choice is not disambiguated by position or gloss, set flag `polysemy` and cap `conf <= 7`.
- **Edition check (`conf = 8`):**
  - If the translation follows TR/Byzantine (`tr-var`) where `step-orig` only has NA/SBLGNT, set flag `tr-var` and `conf = 8`.

## Output Schema
```json
{
  "item": "GEN.1.1",
  "score": 10,
  "problems": [],
  "alternative": null
}
```
