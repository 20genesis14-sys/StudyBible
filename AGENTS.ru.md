[English](AGENTS.md) | **Русский**

# AGENTS.md

## Правила работы

- Два локальных репозитория: `D:\StudyBible` (рабочий, кандидат для
  GitHub) и `D:\StudyBible-priv` (приватная копия).
  **`D:\StudyBible-priv` не трогать никогда** — ни читать, ни писать,
  ни запускать там команды — кроме явной команды пользователя на
  конкретное действие.


- Все планируемые изменения сначала записываются в документы, затем делаются в коде.
- При любом изменении решений, архитектуры или объёма работ обновлять:
  - `docs/SPEC.md` и соответствующий раздел `docs/`;
  - `docs/ROADMAP.md` и `docs/OPEN-QUESTIONS.md`;
  - новый или изменённый ADR в `docs/adr/`;
  - `docs/DECISIONS.md` — источник истины по решениям.
- Код не начинать без явной команды пользователя.
- `unsafe` разрешён, когда оправдан; каждый блок — с комментарием `// SAFETY:` (проверяет clippy).
- Коммит после каждого завершённого шага. Широкие изменения коммитим
  по каталогам (отдельно `docs/`, корневые файлы, `data/`, `apps/`…) —
  на GitHub напротив каждого пути видно сообщение последнего
  затронувшего его коммита, и общие сообщения на пол-репозитория
  смотрятся неаккуратно.
- Репозиторий пока только локальный; CI — локальный скрипт `scripts/ci.ps1`.
- Язык документов — русский.

## Источник решений

`docs/DECISIONS.md` — источник истины; полная карта документов —
`docs/SPEC.md`, здесь её не дублируем.

## Проверка

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ci.ps1
```

Шаги: fmt, clippy (`-D warnings`), test, `cargo check` ядра под `wasm32-unknown-unknown`, `cargo deny check`.
Нужны: `rustup target add wasm32-unknown-unknown`, `cargo install cargo-deny --locked`.
После сборки APK проверить целевой API нативных библиотек:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-apk-api.ps1`
(мост обязан быть не выше minSdk; сборка — с `PUB_CACHE=D:\StudyBible-tools\pub-cache` и `GRADLE_USER_HOME=D:\StudyBible-tools\gradle-home`).
В ядре clippy запрещает `std::fs` и `std::thread::sleep` (`crates/studybible-core/clippy.toml`).

## Данные

Внешние тексты — вне репозитория, в `STUDYBIBLE_DATA` (у пользователя `D:\StudyBible-data`;
`C:\StudyBible-data` — остаточный каталог).
Для Dart-тестов моста выставлять явно: `STUDYBIBLE_DATA=D:\StudyBible-data`.
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

Пути инструментов и особенности машины — `docs/ENVIRONMENT.ru.md`.
