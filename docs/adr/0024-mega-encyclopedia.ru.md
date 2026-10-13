# 0024. Библейская мегаэнциклопедия — модуль `knowledge.sb`

[English](0024-mega-encyclopedia.md) | **Русский**

Статус: дизайн принят (12.10.2026); реализация отложена — трек далёкого
будущего, рядом с форматом v2 и `studybible-text`.

## Контекст

Цель — при чтении стиха дать быстрый доступ к связанным сущностям
(люди, места, предметы, обычаи, понятия, события): карточка сущности,
связи, список упоминаний, статьи и медиа — без привязки к конкретному
переводу и полностью офлайн.

Формат v1 уже позволяет это без форков: необязательные таблицы и ключи
`meta` игнорируются старыми читателями (С-18), а модули-слои без
собственного текста существуют (ADR 0016 `kind="layer"`, ADR 0023 —
слой параллельных мест). Мегаэнциклопедия — такой же независимый слой,
но с собственным контрактом состава, поэтому вводится отдельный `kind`.

## Решение

1. **Модуль `knowledge.sb`** — `.sb` с `meta.kind="knowledge"`, один на
   все переводы; книг и стихового текста не имеет (`books` пустая,
   как у `layer`/`dictionary`). Подключается опционально: без файла
   приложение просто не показывает слой.
2. **Схема** (все таблицы необязательные по правилам v1):

   - `entities(id PK, type, subtype, name, name_original, strongs,
     short_description, article, metadata JSON, image_path, source)` —
     тип сущности текстом (`person`, `place`, `object`, `custom`,
     `concept`, `event`, `creature`, `plant`, `material`, `title`);
     подтип — через `subtype` + `type_hierarchy`.
   - `entity_names(entity_id, name, lang, kind)` — имена и синонимы
     отдельной таблицей (вместо JSON-поля `aliases`): FTS по именам,
     мультиязычность, `kind` = каноническое/алиас/библейская форма.
   - `relationships(id PK, from_entity_id, to_entity_id, relation_type,
     book, chapter, verse, seg, description, weight, source)` — связь
     между сущностями; стих привязки — координатами `(book, chapter,
     verse, seg)`, `NULL` = связь без стиховой привязки.
   - `verse_mentions(book, chapter, verse, seg, entity_id, mention_type,
     context, source)`, PK `(book, chapter, verse, seg, entity_id)` —
     упоминание сущности в стихе; основной путь «стих → сущности».
   - `type_hierarchy(parent_type, child_type)` — таксономия типов для
     валидации и фильтрации/группировки в UI; расширяется данными,
     без миграций схемы.
   - `media(id, entity_id, type, rel_path, caption, order_idx)` —
     изображения/карты/схемы, пути относительно модуля.
   - `embeddings` — опционально и позже (семантический поиск по стихам
     и статьям).
3. **Координаты — канонические коды, не локальные id**: книга в
   координатах — текстовый `book` (`BookCode`: `GEN`, `PSA`, `1SA`),
   плюс `seg` — сегмент части стиха (0 = весь стих, 1..26 = a..z).
   У модуля `kind="knowledge"` своя `books` пуста, поэтому локальный
   `book_id` там не резолвится и запрещён — правило «публичная
   координата = `(BookCode, chapter, verse, segment)`» (DECISIONS).
   Координаты хранятся в версификации `eng`, конверсия в версификацию
   открытого модуля — при чтении через `Versification::convert`.
   Для мест, где автоматическая конверсия неоднозначна или расходится,
   существует опциональная таблица ручного маппинга `verse_map`
   (см. ADR 0016/этап `verse_map` в DECISIONS).
4. **Provenance обязателен**: поле `source` у сущностей, связей и
   упоминаний (`TIPNR`, `OpenBible`, словари, `user`…). Версионирование
   — через `meta` (`content_version`, `updated_at`), граф обновляется
   независимо от переводов.
5. **Связь с существующими данными**: `entities.strongs` ↔ `tokens.strong`
   модулей с `features=strongs`; обогащение `x`-спанов сущностями —
   отдельный отложенный шаг.
6. **Поэтапность**:
   - Этап 1: люди и места (TIPNR + OpenBible — данные уже
     структурированы и лицензионно чисты), таблицы `entities`,
     `entity_names`, `relationships`, `verse_mentions`,
     `type_hierarchy` + минимальная карточка сущности в UI.
   - Далее: `object`/`custom` → `concept`/`event` → природа/материалы;
     статьи наращиваются от `short_description`; затем `embeddings`
     и `media`.
   - ИИ — только на этапе подготовки данных (черновики статей/связей),
     не в рантайме.

## Отложенные возможности (вне этого ADR)

- Пользовательские аннотации поверх базового модуля
  (`user_knowledge.sb`, `source='user'`, приоритет при конфликтах).
- Координаты мест (`lat`/`lon` в `metadata`) и слой карты.
- Обогащение существующих `x`-спанов сущностями графа.

## Последствия

- Формат v1 не меняется структурно: добавляется значение `meta.kind`
  и зафиксированный набор необязательных таблиц; старые читатели
  модуль просто не видят.
- Граф не дублируется в каждом переводе — один модуль на все,
   обновляется независимо (как `openbible-xrefs`, ADR 0023).
- Трудоёмкость сосредоточена в данных: `person`/`place` покрываются
  готовыми источниками, типы `concept`/`event` требуют авторской
  подготовки — это главный риск и причина поэтапности.
- Книги в координатах адресуются кодом `BookCode`, а не локальным
  `book_id`: модуль не имеет собственной `books`, поэтому числовой id
  резолвить нечем. Совместимость набора кодов с модулями проверяет
  `module check`.

## Дополнение 13.10.2026 — ADR 0025 (расширенный Стронг)

- `entities.strongs` хранит **уточнённые номера Стронга** (dStrong,
  например `H0029H` — конкретный человек по имени Авия), а не
  классические; классические номера разрешаются через `lex_base`
  лексикона.
- Источники этапа 1 расширены: ID людей и мест у каждого слова
  TAHOT/TAGNT (`Abraham@Gen.11.26-1Pe`, переносятся в опорный слой
  `step-orig`) дают `verse_mentions` **с точностью до слова**
  (`source='STEPBible'`); TIPNR — сущности и родственные связи;
  OpenBible Geocoding — `lat`/`lon`; участники-референты MACULA —
  дополнительный необязательный источник (`mention_type='referent'`).
- Локализованные `entity_names` (например `lang='ru'`,
  `kind='biblical'`) берутся из слоёв разметки Стронга основного
  перевода языка (для русского — Синодального); через эти же слои
  текст перевода может подсвечивать упоминания.
- Позже — источники понятий: смысловые домены MACULA (лицензию
  проверить), OpenBible Topical Bible (CC BY), Manser's Dictionary of
  Bible Themes (CC BY-SA), TBCWG от STEPBible, когда выйдет.

## Дополнение 13.10.2026 — BibleAquifer как источник контента

Организация `github.com/BibleAquifer` (~73 публичных репозитория)
публикует готовые наборы данных в JSON + Markdown (языковые папки;
для ресурсов Biblica есть `rus`), в основном под CC BY-SA 4.0:

- **`ACAI` — главная находка**: аннотации сущностей на уровне слов и
  фраз в языках оригинала — люди, места, божества, группы, фауна, флора,
  реалии, ключевые термины — с предпочтительными метками, описаниями
  и **связями между сущностями**. Структура записей (`id`/`primary_id`/
  `referred_to_as`, идентификаторы вида `person:Aaron`) ложится почти
  напрямую на `entities`/`entity_names`/`verse_mentions`/`relationships`;
  для упоминаний с точностью до слова это аналог ID людей/мест в
  TAHOT/TAGNT. CC BY-SA © Mission Mutual.
- **Покрытие типов сущностей, которым раньше не было источника**:
  `UBSFloraLexicon` (`plant`), `UBSFaunaLexicon` (`creature`),
  `UBSRealiaLexicon` (`object`/`custom`/`material`),
  `BiblicaStudyNotesKeyTerms` и `FIAKeyTerms` (`concept`, локализованные
  статьи), `DictionaryBibleThemes` (`concept`/`event`),
  `AquiferOpenBibleDictionary` и `UWTranslationWords` (все типы —
  люди/места/термины), `UBSHebrewDictionary`, `UBSGreekNTDictionary`,
  `BDBHebrewLexicon`, `BDBAramaicLexicon` (статьи/`name_original`,
  кросс-ссылки `strongs`).
- **Медиа для `media`/`image_path`**: `BiblicaOpenBibleMaps`,
  `FIAMaps`, `FIAImages`, `UBSImages`, `VideoBibleDictionary`.
- **Тексты на языках оригинала**: `WestminsterLeningradCodex`,
  `SBLGNT`, плюс `text-align` — относится к треку интерлинеара/tokens,
  а не к графу напрямую.
- **Лицензионная заметка**: материалы Biblica study notes — CC BY-SA 4.0
  (© Biblica Inc. 2023; адаптации © Mission Mutual) — обязательна
  атрибуция, производные модули остаются под CC BY-SA, записи идут в
  MODULE-LICENSES. Сам текст NIV проприетарен и в Aquifer отсутствует;
  `BiblicaOpen*` покрывает только арабский/китайский/непальский/
  индонезийский — английского нет. Примечания привязаны к стихам
  (`book/chapter/verse`), а не к переводу — что совпадает с моделью
  координат слоёв.
- **Документация форматов для конвертеров**: репозиторий `docs`
  фиксирует JSON-схемы (`aquifer_resource.schema.json`,
  `aquifer_article.schema.json`, документы по alignments);
  `aquifer-api-client` — готовый Python-клиент.
- Смежный трек (вне этого ADR): `BiblicaStudyNotes` +
  `AquiferOpenStudyNotes` (адаптация примечаний Tyndale) + BookIntros +
  словари — контентная база будущей «своей учебной Библии»,
  см. ROADMAP (локальный).
