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
- Навигация в `ReadingScreen`: голые `Navigator.pop`/`maybePop`/
  `pushReplacement` запрещены — `PopScope(canPop: false)` их молча
  проглатывает. Все осознанные выходы с маршрута — через `_popRoute()`.
  Две семантики «назад» названы и разведены: `_stackBack()` (история
  позиций — системный жест, Alt+←/→, X1/X2 мыши) и `_hierarchyBack()`
  (строго вверх: глава → сетка глав → сетка книг — только стрелка шапки).
- Документы двуязычные: английский `X.md` — первичный, русский
  `X.ru.md` — зеркало (кроме `docs/ROADMAP.md` — русский, только
  локальный).
- Агентская обвязка улучшается петлёй из `docs/AGENT-HARNESS.ru.md`
  (ADR 0031): механические правила — в `scripts/check-agent-rules.ps1`
  (шаг `ci.ps1`; комментарий `// nav:` в строке — исключение под
  ревью), поведенческие прогоны — на замороженных карточках `evals/`.

## Источник решений

`docs/DECISIONS.md` — источник истины; полная карта документов —
`docs/SPEC.md`, здесь её не дублируем.

## Проверка

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ci.ps1
```

Шаги: fmt, clippy (`-D warnings`), test, `cargo check` ядра под `wasm32-unknown-unknown`, `cargo deny check`,
agent-rules (`check-agent-rules.ps1`)
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

## Сборки в WSL — постоянное правило

Вся Linux-сторона работы (сборки и проверки F-Droid,
`flutter build linux`, тяжёлые git/файловые операции) выполняется
**внутри ext4-файловки WSL**, никогда через `/mnt/d`
(9p — в десятки раз медленнее на метаданных):

- Чекаут и сборка — из `~/StudyBible` в дистрибуции Ubuntu
  (origin `file:///mnt/d/StudyBible`; синхронизация — `git fetch`
  + checkout). `D:\StudyBible` остаётся мастер-копией.
- Рабочее дерево F-Droid — `/home/vagrant/fdroiddata` (канонический
  путь, повторяет buildserver — нужно для паритета `fdroid verify`).
- `D:\StudyBible-fdroid` — устаревшая копия, собирать из неё нельзя.
- `/mnt/d` используется только для входа и выгрузки артефактов
  (например, `D:\StudyBible-dist`).
- Полная раскладка и особенности `fdroid verify` —
  `docs/ENVIRONMENT-ru.md` («Раскладка WSL»).
