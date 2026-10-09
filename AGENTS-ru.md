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
- Коммит после каждого завершённого шага; широкие изменения — по
  каталогам (отдельно `docs/`, корневые файлы, `data/`, `apps/`…), чтобы
  на GitHub у каждого пути было читаемое сообщение.
- Репозиторий на GitHub (`20genesis14-sys/StudyBible`), рабочая ветка
  `dev`, релизы — в `main`; CI — локальный скрипт `scripts/ci.ps1`.
- Документы двуязычные: английский `X.md` — первичный, русский
  `X.ru.md` — зеркало (кроме `docs/ROADMAP.md` — русский, только
  локальный).

## Источник решений

`docs/DECISIONS.md` — источник истины; полная карта документов —
`docs/SPEC.md`, здесь её не дублируем.

## Проверка

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ci.ps1
```

Шаги: fmt, clippy (`-D warnings`), test, `cargo check` ядра под `wasm32-unknown-unknown`, `cargo deny check`
— зависимости и переменные сборки в `docs/ENVIRONMENT-ru.md`.
После сборки APK проверить целевой API нативных библиотек:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-apk-api.ps1`
(мост обязан быть не выше minSdk).
В ядре clippy запрещает `std::fs` и `std::thread::sleep` (`crates/studybible-core/clippy.toml`).

Изменения во Flutter (каталог `apps/studybible-flutter`):
`D:\StudyBible-tools\flutter\bin\flutter analyze`; тестам моста нужна
`STUDYBIBLE_DATA=D:\StudyBible-data`.

## Данные

Внешние тексты (переводы, модули) — вне репозитория, в `STUDYBIBLE_DATA`
(`D:\StudyBible-data`) — в git их коммитить нельзя. Команды
fetch/check-data и структура `data/` — в `docs/ENVIRONMENT-ru.md`.

## Окружение

Пути инструментов и особенности машины — `docs/ENVIRONMENT-ru.md`.
