# 05. Формат модуля v1

Статус: реализовано в `crates/studybible-store` (MVP 2). Нормативная форма — к 1.0.
Решения — ADR 0003 (недоверенный SQLite, FTS в кэше), ADR 0007 (поток чтения).

## Файл

SQLite-база, кодировка UTF-8. Подпись: `PRAGMA application_id = 0x53424D31` (`SBM1`).
В `meta` обязателен ключ `format_version = "1"`.

## Таблицы

```sql
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE books(code TEXT PRIMARY KEY, ord INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '');
CREATE TABLE book_headers(book TEXT NOT NULL, marker TEXT NOT NULL, text TEXT NOT NULL,
                          PRIMARY KEY(book, marker));
CREATE TABLE blocks(book TEXT NOT NULL, chapter INTEGER NOT NULL, seq INTEGER NOT NULL,
                    marker TEXT NOT NULL DEFAULT '', PRIMARY KEY(book, chapter, seq));
CREATE TABLE spans(book TEXT NOT NULL, chapter INTEGER NOT NULL, block INTEGER NOT NULL,
                   seq INTEGER NOT NULL, kind TEXT NOT NULL, num INTEGER,
                   style TEXT NOT NULL DEFAULT '', attrs TEXT NOT NULL DEFAULT '',
                   caller TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book, chapter, block, seq));
CREATE TABLE verses(book TEXT NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    text TEXT NOT NULL, PRIMARY KEY(book, chapter, verse));
```

- `books` — коды USFM/OSIS книг в порядке модуля (`ord`) с заголовком книги.
- `book_headers` — заголовки книги из USFM (`h`, `toc1`, `mt1`…), кроме `id`.
- `blocks` — поток чтения: маркер USFM блока (`p`, `q1`, `s1`, `d`…), пустой — продолжение.
- `spans` — строчные промежутки блока. `kind`: `v` — маркер стиха (`num`),
  `t` — текст (`style` — символьный стиль USFM, `attrs` — атрибуты слова, например
  `strong="H7225"`), `f`/`x` — сноска/перекрёстная ссылка (`caller`, `text`).
- `verses` — производный плоский текст стиха без сносок и заголовков
  (собирается `Chapter::verse_texts`, надписание псалма — стих 0). Для кэша поиска и вывода.

## Ключи `meta`

`format_version`, `id`, `title`, `language` (BCP 47), `direction` (`ltr`/`rtl`),
`versification` (`rsc`, `org`…), `name_profile` (`syn`, `alt`, `en`), `book_order`
(`list`, `syn`), `version`, `license`, `attribution`, `source`, `content_hash` (SHA-256
потока чтения — часть ключа кэша поиска), `required` (список обязательных возможностей
через запятую). Прочие ключи сохраняются в `extra` и не ломают чтение.
Флаги прав (копирование, сеть, ИИ, плагины) в эти ключи не входят — вопрос № 15.

## Безопасное открытие (`Module::open`)

- `SQLITE_OPEN_READ_ONLY` + `PRAGMA query_only=ON` — запись запрещена.
- `PRAGMA trusted_schema=OFF` и `SQLITE_DBCONFIG_DEFENSIVE=ON` — защита от вредоносной
  схемы; `DQS` выключен.
- Проверки: `application_id`, наличие всех таблиц, ожидаемые столбцы (подготовка
  `SELECT … LIMIT 0`), `format_version`, непустой `id`. Любая обязательная возможность
  из `required` — отказ (`UnsupportedFeature`), т. к. поддерживаемых пока нет.

## Запись (`ModuleWriter`)

`create` → `add_book` → `add_chapter` (пишет `blocks`, `spans`, `verses`, копит хэш) →
`finish` (пишет `content_hash`, `COMMIT`, `PRAGMA optimize`). Всё в одной транзакции.

## Необязательные расширения (ADR 0016, до заморозки 1.0)

Ничего из этого не обязательно и не идёт в `required`.

- `meta.kind`: `bible` | `interlinear` | `commentary` | `dictionary` | `layer` | `critical`.
- `meta.features`: `strongs,morph,tokens,alignment,variants` (через запятую).
- `tokens(book, chapter, verse, seq, surface, lemma, strong, morph, gloss)` —
  слова оригинала. Источник: OSIS `<w lemma morph>`, USFM `\w …|strong lemma x-morph\w*`,
  теги Стронга MyBible/BibleQuote. Заполняет конвертер.
- `alignment(book, chapter, verse, token_seq, target_block, target_seq, target_offset)` —
  связь токена с текстом перевода/глоссы. Вход автора — TSV `ссылка  оригинал  глосса`.
  Старый вид подстрочника (`spans.attrs` = `gr="…"`) читается без изменений.
- `variants(id, book, chapter, verse, token_from, token_to)`,
  `readings(variant_id, seq, text, is_base)`, `witnesses(reading_id, siglum)` —
  критический аппарат. Вход — TSV/JSON.
- `.sbz` — `.sb`, сжатый zstd, только для передачи; импорт распаковывает.

- Место сноски и ссылки в стихе: span `f`/`x` уже стоит в потоке на своём месте
  (часть стиха). Принято (ADR 0015, 0016): текст привязки из
  USFM `\fq`/`\xq`, OSIS `<catchWord>` и буква части из `\fr`/`\xo` (`1:1a`).

Точные столбцы и индексы фиксируются при реализации, до заморозки 1.0.
Инструменты: `studybible module check`, `studybible module pack`, шаблоны TSV.

## Эволюция формата

Менять или удалять существующие поля нельзя. Новое — только необязательные таблицы
и необязательные ключи `meta`. Возможность, без которой читать нельзя, идёт в `required`
— старые читатели откажутся с понятной ошибкой.
