# Test fixtures

**English** | [Русский](README.ru.md)

- `references.tsv` — parsed reference fixtures
  (`crates/studybible-core/tests/`).
- `versification.tsv` — versification witness verses from real texts
  (`crates/studybible-convert/tests/stage0_fixtures.rs`, SKIPPED without
  the data directory).
- `vrs_golden.json` — the canonical versification gold standard:
  `to_org` for all verses on the left sides of mappings, `from_org` —
  right sides, `skipped` and sample cross-conversions (rsc↔eng psalms
  89/90/141/142, vul DAG/S3Y). Checked by both Rust
  (`crates/studybible-core/tests/vrs_golden.rs`) and the Dart port
  (`apps/studybible-flutter/test/vrs_golden_test.dart`) — catches any
  port divergence on all mapping rows.

Regenerating the gold file after edits to `.vrs` or the parser logic:

```
$env:VRS_GOLDEN='write'; cargo test -p studybible-core --test vrs_golden
```

A normal `cargo test` run compares against the saved file.
