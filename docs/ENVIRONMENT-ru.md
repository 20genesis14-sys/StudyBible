[English](ENVIRONMENT.md) | **Русский**

# Окружение

Пути инструментов и локальные особенности рабочей машины.

## Расположение

- Весь проект на диске `D:`: репозиторий `D:\StudyBible`, данные
  `D:\StudyBible-data`, инструменты `D:\StudyBible-tools`.
- Windows; Rust 1.99.0 (cargo, rustup установлены).
- Flutter SDK 3.47.6 — `D:\StudyBible-tools\flutter` (в PATH нет, вызывать
  `D:\StudyBible-tools\flutter\bin\flutter`); Android SDK —
  `D:\StudyBible-tools\android-sdk`.
- Python — `C:\Users\Ольга\AppData\Local\Programs\Python\Python311\python.exe`
  (команда `python` не работает — алиас Microsoft Store).
- Git 2.55.0 (`C:\Program Files\Git\cmd\git.exe`). В уже открытых оболочках
  PATH может быть старым — перечитать его из реестра или открыть новую
  оболочку.

## Особенности

- Оболочка по умолчанию (bash) — Git Bash; сборку и проверки Windows
  запускать в PowerShell.
- Скрипты `.ps1` с кириллицей сохранять в UTF-8 с BOM: Windows PowerShell 5
  иначе читает их как ANSI.
- Сборка Flutter — с изолированными кэшами:
  `PUB_CACHE=D:\StudyBible-tools\pub-cache`,
  `GRADLE_USER_HOME=D:\StudyBible-tools\gradle-home`.
  Это не косметика: в пути профиля `C:\Users\Ольга` есть кириллица,
  и запущенный Gradle'ом `ninja -C` не может в него `chdir` —
  CMake-шаги плагинов (например, `jni`) падают с
  `ninja: fatal: chdir ... No such file or directory`. Без
  `PUB_CACHE` сборка молча уходит в
  `C:\Users\Ольга\AppData\Local\Pub\Cache` и упирается ровно в это.
  Аварийный обход, если переменная не задана: junction
  `mklink /J C:\pcache <дефолтный pub cache>` и `PUB_CACHE=C:\pcache`.
- Зависимости CI: `rustup target add wasm32-unknown-unknown`,
  `cargo install cargo-deny --locked`.

## Раскладка WSL (F-Droid / Linux-сборки)

Дистрибуция `Ubuntu` хранится на `D:` (`D:\WSL\Ubuntu`, ext4.vhdx) —
всё внутри `~` физически на `D:`, но доступно как родная ext4,
без штрафа `/mnt/d` (9p/DrvFs) на метаданных
(`git status` по репо: ~3,4 с через `/mnt/d` против ~0,1 с в `~`).

- `~/StudyBible` — второй чекаут репо в ext4;
  `origin = file:///mnt/d/StudyBible`, синхронизация через `git fetch`
  + checkout. `D:\StudyBible` остаётся мастер-копией для Windows-инструментов.
- `/home/vagrant/fdroiddata` — **каноническое** рабочее дерево F-Droid
  (повторяет раскладку buildserver `/home/vagrant/fdroiddata/build/<appid>`,
  чтобы пути в APK совпадали для `fdroid verify`). Сборки и проверки
  запускаются отсюда пользователем `gedeon`.
- `~/fdroid-fork` — форк fdroiddata для апстрим-MR (рецепт с источником
  GitHub, `binary:` + `AllowedAPKSigningKeys`).
- `~/flutter` — чекаут Flutter SDK, пин `5fc346839b` (3.47.6);
  используется F-Droid-сборками (srclib) и Linux-сборкой.
- `~/Android/Sdk` — Android SDK + NDK 28.2 в ext4; rustup 1.99.0
  в `~/.cargo`.
- `D:\StudyBible-fdroid` — **устаревшая** копия старого локального
  fdroiddata; оставлена как бэкап, собирать из неё не надо.
- `fdroid verify`: по умолчанию тянет APK с `f-droid.org`; для локального
  сравнения кладём эталонные APK в `tmp/<имя>.apk` и запускаем
  `fdroid verify --reuse-remote-apk`.
- Правило: исходники, деревья сборки и кэши — внутри ext4 (`~` или
  `/home/vagrant`); `/mnt/d` — только вход и выгрузка артефактов.

## Внешние данные (`STUDYBIBLE_DATA`)

`D:\StudyBible-data` (`C:\StudyBible-data` — остаточный каталог).
Каталог намеренно вне репозитория: тексты переводов нельзя выкладывать
на GitHub вместе с кодом.

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1        # скачать и сверить SHA-256
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1 -Pin   # перезакрепить хэши после обновления источника
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-data.ps1        # сверка содержимого
```

В репозитории: `data/canon/canon-66-knig.md` — исходный список канона
от пользователя; `data/profiles/` — профили книг и неканонического;
`data/versification/` — файлы Paratext (MIT); `data/tests/` —
испытательные наборы. Проверки —
`crates/studybible-convert/tests/stage0_fixtures.rs`; проверки по текстам
пропускаются (SKIPPED), если каталога данных нет.
