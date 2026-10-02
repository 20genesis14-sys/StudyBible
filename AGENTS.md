# AGENTS.md

## Правила работы

- Все планируемые изменения сначала записываются в документы, затем делаются в коде.
- При любом изменении решений, архитектуры или объёма работ обновлять:
  - `docs/SPEC.md` и соответствующий раздел `docs/`;
  - `docs/ROADMAP.md` и `docs/OPEN-QUESTIONS.md`;
  - новый или изменённый ADR в `docs/adr/`;
  - `docs/DECISIONS.md` — источник истины по решениям.
- Код не начинать без явной команды пользователя.
- `unsafe` разрешён, когда оправдан; каждый блок — с комментарием `// SAFETY:` (проверяет clippy).
- Коммит после каждого завершённого шага.
- Репозиторий пока только локальный; CI — локальный скрипт `scripts/ci.ps1`.
- Язык документов — русский.

## Источник решений

- `docs/DECISIONS.md` — текущие решения; `docs/SPEC.md` — оглавление; `docs/adr/` — обоснования;
  `docs/ROADMAP.md` — ход работ; `docs/OPEN-QUESTIONS.md` — открытые вопросы.
- `C:\Users\Ольга\Documents\Принятые решения v2.txt` — исходная редакция, перенесена в `docs/DECISIONS.md`, больше не обновляется.

## Проверка

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ci.ps1
```

Шаги: fmt, clippy (`-D warnings`), test, `cargo check` ядра под `wasm32-unknown-unknown`, `cargo deny check`.
Нужны: `rustup target add wasm32-unknown-unknown`, `cargo install cargo-deny --locked`.
В ядре clippy запрещает `std::fs` и `std::thread::sleep` (`crates/studybible-core/clippy.toml`).

## Данные

Внешние тексты — вне репозитория, в `STUDYBIBLE_DATA` (по умолчанию `C:\StudyBible-data`).
Каталог намеренно не внутри репозитория: тексты переводов нельзя выкладывать на GitHub вместе с кодом.

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1        # скачать и сверить SHA-256
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1 -Pin   # перезакрепить хэши после обновления источника
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-data.ps1        # сверка содержимого
```

`data/canon/canon-66-knig.md` — исходный список канона от пользователя.
`data/profiles/` — профили книг и неканонического; `data/versification/` — файлы Paratext (MIT);
`data/tests/` — испытательные наборы. Проверки — `crates/studybible-convert/tests/stage0_fixtures.rs`;
проверки по текстам пропускаются (SKIPPED), если нет каталога данных.

## Окружение

- Скрипты `.ps1` с кириллицей сохранять в UTF-8 с BOM: Windows PowerShell 5 иначе читает их как ANSI.

- Оболочка по умолчанию (bash) — WSL Ubuntu; сборку и проверки Windows запускать в PowerShell.

- Windows; Rust 1.98.1 (cargo, rustup установлены).
- Git 2.55.0 (`C:\Program Files\Git\cmd\git.exe`). В уже открытых оболочках PATH может быть старым — перечитать его из реестра или открыть новую оболочку.
