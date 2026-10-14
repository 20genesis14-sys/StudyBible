---
name: strongs-verse-align
description: Align unresolved Bible translation words (w1) to STEPBible original-language candidates (wid + dStrong) with role (head|aux|added) and confidence (0-10)
---

# `strongs-verse-align` — Step 7a of the Strong's Layer Pipeline (ADR 0025)

## Input (JSON per verse)
- `book`, `chapter`, `verse`
- `words`: numbered target words from `studybible tokenize` (`w1`, 0-based)
- `candidates`: original-language tokens of the verse from `step-orig.sb`:
  - `wid` (`Gen.1.1#01`), `surface`, `xlit`, `dstrong` (space-separated morphs), `gloss`, `sense`, `morph`, `editions` (`N`, `K`, etc.)
- `pre_links`: deterministic Contour-1 decisions (`word`, `refs`, `dstrong`, `role`, `conf`)
- `unresolved_words`: word indices requiring resolution (intra-verse polysemy, edition divergence, or untagged idioms)

## Hard Rules (Version `1.0`)
1. **Closed candidate set:** `refs` may ONLY reference `wid` addresses present in `candidates` of the same verse (or mapped parallel verse from `verse_map.json`). For TR-only translations (e.g. KJV) where a word comes from a Textus Receptus reading absent in `step-orig` critical edition, `dstrong` must exist in `strongs-step.sb` and flag `tr-var` is set.
2. **Every candidate accounted for:** Every candidate `wid` is either linked to at least one target word or implicitly absorbed in a phrase/idiom.
3. **Syntactic roles (`flags`):**
   - `head`: content word carrying the lexical stem (`noun`, `verb`, `adj`, `adv`, `proper name`).
   - `aux`: function word (`preposition`, `article`, `conjunction`, `auxiliary verb`, `pronoun suffix`).
   - `added`: translator-supplied word with no source morpheme (`refs: []`, `dstrong: ""`, `conf: 9..10` if marked `\add`, else `7..8`).
4. **No copyrighted prompts:** Only CC BY / CC0 / Public Domain glosses (STEPBible, BSB) may appear in prompts.

## Output Schema
```json
{
  "verse": 1,
  "links": [
    {
      "word": 0,
      "refs": ["Gen.1.1#01"],
      "dstrong": "H9003",
      "role": "aux",
      "conf_self": 10,
      "flags": ["aux"],
      "note": ""
    }
  ]
}
```
