# Module licenses

**English** | [Русский](MODULE-LICENSES.ru.md)

How `.sb` / `.sbz` modules are licensed, what the bundled modules
carry, and what a new module must declare. Code licensing is separate —
see [ADR 0002](adr/0002-licensing.md) (`MIT OR Apache-2.0`,
"StudyBible contributors").

## Principles

- `.sb` / `.sbz` is a container (SQLite, optionally zstd-packed —
  ADR 0016 §6). The container itself has no license; the license
  belongs to the **text/data inside**.
- The engine's license does **not** cover module content, and a
  module's license does not cover the code.
- Every module carries `license`, `attribution` and `source` in its
  `meta` table; the app shows them to the user. Modules without a
  declared license are treated as **not redistributable**.
- We do not perform a detailed legal review of texts (ADR 0002), but
  a module may be bundled or published only when its status is
  documented in this file.
- "Public domain" is claimed only when verified against the source;
  otherwise the status is marked *needs verification*.

## Bundled modules (shipped in `assets/modules/`)

| ID | Title | Lang | Kind | License (meta) | Attribution | Redistributable | Notes |
|---|---|---|---|---|---|---|---|
| `russyn` | Синодальный перевод (1876) | ru | bible | public domain | eBible.org (russyn) | yes | 1876 text, copyright expired; source eBible.org `russyn` |
| `eng-kjv2006` | King James Version (1769, Strong's) | en | bible | public domain вне Великобритании (в UK — Letters Patent) | eBible.org (eng-kjv2006) | yes, outside UK | KJV is under perpetual Crown copyright in the UK (Letters Patent); public domain elsewhere. Strong's numbers markup per eBible.org source |
| `openbible-xrefs` | Cross-references | en | layer (xrefs) | CC-BY | OpenBible.info cross-references | yes, with attribution | Source: <https://www.openbible.info/labs/cross-references/>; requires credit — shown in module info |

## Other modules

- `engwebp` and any other converted texts: **user import only** —
  source files live outside git in `STUDYBIBLE_DATA`, are not
  committed and not bundled. Status must be recorded here before any
  distribution.
- Third-party modules a user imports are the user's responsibility;
  the app displays whatever `license`/`attribution` the module
  declares.

## Requirements for a new module

Before a module is bundled or published, record in `meta` and here:

1. `id`, title, language (BCP 47), version/date.
2. `source` — where the text came from (URL/edition).
3. `license` — SPDX id or a short status line; explicit "public
   domain" only when verified.
4. `attribution` — the credit line the license requires (empty if
   none).
5. Modifications made by the converter (normalization, versification
   mapping) if the license requires noting them.
6. Redistribution permission — bundling, network delivery, AI use.

A module failing these checks must not ship in release builds; for
F-Droid source builds unclear modules are excluded (`scandelete`)
until verified.

## F-Droid notes

The F-Droid scanner flags binary-looking files; `.sbz` modules are
data assets that stay in the source tree because each has a declared
license in `meta` and a row in the table above. Keeping this document
current is part of adding or updating any bundled module.

## Third-party non-module assets

- RUAccent dictionaries (`assets/voice/ru/*.tsv`) and model —
  `LICENSE-ruaccent.txt` in the repo root.
- Fonts, engine dependencies — `deny.toml` / `cargo deny`, and the
  licenses of vendored web decoders (`web/zstd/`, BSD-3 @bokuweb).

## Planned external sources (not yet modules)

- **BibleAquifer** resources (`github.com/BibleAquifer`, long-term
  "own study Bible" track — DECISIONS 2026-10-13): study notes,
  book intros, key terms, dictionaries, maps/images — mostly
  **CC BY-SA 4.0**, © Biblica Inc. / Tyndale House Publishers /
  unfoldingWord / UBS, adaptations © Mission Mutual. Derived `.sb`
  modules require attribution in `meta` and stay under CC BY-SA.
  `ACAI` entity data likewise CC BY-SA © Mission Mutual.
