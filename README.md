# StudyBible

Кроссплатформенное приложение для чтения и изучения Библии.

Две равноценные цели:

1. **Чтение** — простое, удобное, быстрое приложение.
2. **Изучение** — параллельные места, лексикон Стронга, сравнение переводов,
   подстрочники, оригиналы, комментарии.

Ядро написано на Rust по схеме «порты и адаптеры», интерфейс — Flutter
(Android, Windows, macOS, Linux, web). Данные пользователя хранятся только
на его устройстве.

Тексты переводов в этот репозиторий не входят. Они лежат в отдельном каталоге
`STUDYBIBLE_DATA` (рядом с репозиторием, по умолчанию `..\StudyBible-data`),
чтобы публикация кода не унесла с собой сами Библии.

## Системные требования

| Платформа | Минимум |
|---|---|
| Android | Android 8.0 (API 26); APK собран под armeabi-v7a, arm64-v8a и x86_64 |
| Windows | Windows 10 (64-разрядная) и новее |
| Web | Современный браузер с поддержкой WebAssembly (Chrome, Firefox, Safari, Edge) |
| Linux / macOS / iOS | Сборка из исходников (Flutter 3.47+, Rust 1.99+) |

Статус: 1.0.1. Документация — [docs/SPEC.md](docs/SPEC.md),
ход работ — [docs/ROADMAP.md](docs/ROADMAP.md), открытое — [docs/OPEN-QUESTIONS.md](docs/OPEN-QUESTIONS.md),
изменения — [CHANGELOG.md](CHANGELOG.md).

## Структура

| Путь | Назначение |
|---|---|
| `crates/studybible-core` | Ядро: домен и порты |
| `crates/studybible-convert` | Конвертер форматов модулей (библиотека) |
| `crates/studybible-store` | Модуль SQLite, поиск, данные пользователя |
| `crates/studybible-accent` | Лексикон и расстановка ударений для TTS |
| `apps/studybible-cli` | Консольная оболочка (`studybible`) |
| `apps/studybible-flutter` | Приложение (Flutter + Rust-мост) |
| `data/` | Канон, профили книг, версификации, испытательные наборы |
| `docs/` | Спецификация, решения (DECISIONS), ADR, планы |

## Сборка

Консоль и ядро:

```
cargo build
cargo test
cargo run -p studybible-cli
```

Приложение: `apps/studybible-flutter`, обычный `flutter build`
(инструкции по платформам — в `docs/`).

## Лицензия

Код распространяется на условиях на ваш выбор:

- MIT ([LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

Тексты Библии и другие данные распространяются отдельно,
у каждого модуля своя лицензия и атрибуция.
