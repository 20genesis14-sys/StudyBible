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
- Зависимости CI: `rustup target add wasm32-unknown-unknown`,
  `cargo install cargo-deny --locked`.
