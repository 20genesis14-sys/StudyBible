# Испытательные наборы

[English](README.md) | **Русский**

- `references.tsv` — ссылки-разборы (`crates/studybible-core/tests/`).
- `versification.tsv` — стихи-свидетели версификаций по реальным текстам
  (`crates/studybible-convert/tests/stage0_fixtures.rs`, SKIPPED без
  каталога данных).
- `vrs_golden.json` — канонический эталон версификаций: `to_org` для всех
  стихов левых сторон соответствий, `from_org` — правых, `skipped` и
  выборочные cross-конверсии (rsc↔eng псалмы 89/90/141/142, vul DAG/S3Y).
  Сверяют Rust (`crates/studybible-core/tests/vrs_golden.rs`) и Dart-порт
  (`apps/studybible-flutter/test/vrs_golden_test.dart`) — ловит любое
  расхождение портов на всех строках маппингов.

Перегенерация эталона после правок `.vrs` или логики парсера:

```
$env:VRS_GOLDEN='write'; cargo test -p studybible-core --test vrs_golden
```

Обычный прогон `cargo test` сравнивает с сохранённым файлом.
