# Трек «Расширенный Стронг» — спек для передачи работы

[English](HANDOFF.md) | **Русский**

Статус: план утверждён пользователем 13.10.2026. Запись решения:
[ADR 0025](../adr/0025-extended-strongs-interlinear.ru.md) (+ дополнение
в [ADR 0024](../adr/0024-mega-encyclopedia.ru.md)). Документ
самодостаточен: новый инженер или модель с этим файлом, репозиторием и
`STUDYBIBLE_DATA` должны суметь продолжить работу без исходной
переписки.

**Текущее состояние и измеренные числа: [PROGRESS.ru.md](PROGRESS.ru.md)** —
читать сразу после этого файла; он важнее ожиданий ниже (например,
RUSSYN от Clear оказался непригоден, фаза 8.3 идёт конвейером).

---

## 0. Прочитать в первую очередь

- Репозиторий: `D:\StudyBible` (основная копия). **Никогда не трогать
  `D:\StudyBible-priv`.** `C:\StudyBible\StudyBible` — устаревший клон,
  не использовать.
- Правила: `AGENTS.md` (сначала документы, потом код; публикуемые
  документы двуязычные; коммит по каталогам; без push без
  пользователя; CI = `scripts\ci.ps1`). Источник истины решений —
  `docs/DECISIONS.md`.
- Не начинать код без явной команды пользователя; фазы ниже утверждены,
  но начало каждой фазы подтверждается у пользователя.
- Внешние данные — в `STUDYBIBLE_DATA` = `D:\StudyBible-data`; тексты и
  модули никогда не коммитятся. Python на этой машине — `py`.
- Формат модулей: `docs/spec/en/05-module-format-v1.md` (правила S,
  необязательные таблицы S-20, упаковка `required="pack"` ADR 0022).
- С пользователем — по-русски; пользователь не программист-лингвист —
  результаты объяснять просто.

## 1. Цели и что не входит

Цели (по порядку):

1. Универсальный расширенный лексикон Стронга (английский), ключ —
   уточнённый номер (dStrong).
2. Английские подстрочники (контекстный и словарный).
3. Конвейер разметки номерами Стронга для переводов без них;
   проверка на английском (BSB — главный, KJV — второй) — **порог
   качества**.
4. Русский: накладной лексикон, словарный подстрочник, слой разметки
   Синодального; затем другие языки.
5. Данные этапа 1 мегаэнциклопедии (люди, места) — ADR 0024.

Сейчас не входит: Септуагинта (TAGOT не вышел), неканонические книги
(нет в TAHOT/TAGNT; подстрочник Apocrypha от OpenBible — вариант на
потом), ИИ в рантайме, полный LSJ в основном лексиконе.

100 % совпадения с любым эталоном не ожидается: переводы сделаны с
разных исходных текстов (TR против NA, кетив/кре, отсутствующие
стихи).

## 2. Перечень материалов

Всё в `D:\StudyBible-data\sources\strongs\` (закреплено в
`data/sources.json`, повторная загрузка:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-data.ps1 -Only <ids>`).
`MANIFEST.json` в этой папке перечисляет каждый файл с SHA-256 и
лицензией. id в `sources.json`: `stepbible-data`, `oshb-lexicon`,
`bsb-tables`, `macula-hebrew`, `macula-greek`, `clear-alignments`,
`asv-alignment-data`, `asv-bible`, `openbible-geocoding`,
`abbott-smith`, `ubs-dictionaries`, `bdb-full` (≈ 1 ГБ) — плюс набор
BibleAquifer (см. ниже). `macula-hebrew.tsv` в оригинале лежит в
Git LFS и скачивается с `media.githubusercontent.com`; `catalog.tsv`
Clear Alignments остаётся указателем LFS (не нужен). `-Pin` заново
скачивает всё, что обрабатывает.

| id / папка | Содержимое | Лицензия | Роль |
|---|---|---|---|
| `stepbible` | STEPBible-Data: TAHOT ×4, TAGNT ×2, TBESH, TBESG, TFLSJ ×2, TEHMC, TEGMC, TIPNR, TVTMS, TTESV, README | CC BY 4.0; TTESV — CC BY-NC; TBESH Meaning — © Online Bible | основа |
| `oshb-lexicon` | OpenScriptures HebrewLexicon: BrownDriverBriggs.xml, LexicalIndex.xml, AugIndex.xml, HebrewStrong.xml, схемы, PDF | CC BY 4.0 / общ. достояние | определения иврита (по умолчанию) |
| `bsb` | `bsb_tables.tsv` (Berean) | CC0 | главный эталон + разрешённый вход |
| `macula-hebrew`, `macula-greek` | TSV MACULA (WLC; SBLGNT + Nestle1904) | репозитории CC BY 4.0 © Biblica; `@ln`/`@domain` (MARBLE) и `@sdbh` (SDBH) — «used with permission» UBS → **только внутренняя сверка, в модули не включать** | сверка, греческие значения, референты, мост к Clear |
| `clear-alignments` | Clear-Bible/Alignments: ручные разметки eng BSB/YLT, rus RUSSYN, fra, spa, por, arb, hin, hau… | CC BY 4.0 | эталоны; RUSSYN — возможно прямой источник |
| `asv-alignment`, `asv-bible` | Подстрочник ASV от OpenBible: правила, драйвер, проверенные решения, USX с выравниванием | код MIT, на решения прав не заявлено, ASV — общ. достояние | образец процесса + эталон для сравнения |
| `openbible-geocoding` | места с координатами | CC BY 4.0 | мегаэнциклопедия |
| `abbott-smith` | греческий лексикон Abbott-Smith (TEI) | общ. достояние | греческие определения, замена ML |
| `esv/` (локально, повторно не скачать) | `ttesv.txt`, `esv2016_*.sqlite`, `build_esv2016_strongs.py`, `make_variants.py`, `converter.py`, README, исходный JSON | текст ESV © Crossway — не коммитить и не распространять | эталон ESV по отложенным книгам |
| `ubs-dictionaries` | UBS Dictionary of Biblical Hebrew (из SDBH, ~99 % слов ВЗ) и UBS Dictionary of NT Greek (переработанный Louw–Nida): значения, глоссы, ссылки, семантические домены; en-JSON | **CC BY-SA 4.0** © UBS — легальный канал публикации доменов/значений | `lex_def` + поле домена; сверка @ln/@sdbh |
| `bdb-full` | полная несокращённая BDB (eliranwong), JSON `DictBDB` (8 090 статей по ключу H…) + CSV с маппингом | общественное достояние | `lex_def` уровень «глубокая статья» (наряду с OSHB) |
| `bdb-aramaic` | Aquifer: арамейский раздел BDB, `English-json`+`alignments` | CC0 | `lex_def` для арамейских номеров H10xxx |
| `bdb-hebrew-aq` | Aquifer: BDB Hebrew, `English-json`+`alignments` | CC0 | `lex_def` + **alignments размечают значения по стихам** — корпус снятой неоднозначности |
| `rsb-aquifer` | Aquifer RussianSynodalBible: usfm/json + **234 908 записей ручного пословного выравнивания WLCM/SBLGNT→RUSSYN** (все 66 книг, `process=manual`, формат Burrito, ID MACULA) | **CC0** | второй русский эталон (наряду с rsts), *публикуемый* — лицензия открытая; приор и gold фазы 8.3 |
| `acai` | Aquifer ACAI: сущности people/places/deities/groups/fauna/flora/realia/keyterms — связи, метки на 11 яз. (вкл. rus), referents по ID MACULA, кросс-ворк на TIPNR | CC BY-SA 4.0 © Mission Mutual | граф (ADR 0024, доп. 13.10); в лексиконе — данные имён и entity_names |
| `aquifer-obd` | Aquifer Open Bible Dictionary (адаптация Tyndale OBD) en+ru | CC BY-SA 4.0 (Tyndale→Mission Mutual) | статьи сущностей, entity_names(ru) |
| `uw-tw`, `fia-keyterms`, `biblica-keyterms` | ключевые термины uW / FIA / Biblica (en; у FIA и Biblica есть ru) | CC BY-SA 4.0 | concept-сущности графа, карточки терминов |
| `ubs-fauna`, `ubs-flora`, `ubs-realia` | лексиконы UBS: животные, растения, реалии (md) | CC BY-SA 4.0 © UBS | сущности fauna/flora/object графа |
| `dict-themes` | Dictionary of Bible Themes (Manser) | CC BY-SA 4.0 | concept/event графа |
| `analysis/` | скрипты, которыми получены выводы 12–13.10.2026 (`senses.py`, `compare.py`, `quality.py`, `q2.py`) | — | воспроизвести выводы |

В `sources/…/aquifer/` также лежит контент трека «учебная Библия»
(после 1.0): `aquifer-osn`, `biblica-notes` (en+ru), `sil-tn`,
`uw-tn`, `uw-tq`, `uw-tm` (en), `fia-tg`, `uw-obs`,
`video-bible-dict` — все CC BY-SA 4.0.

Уже есть в `D:\StudyBible-data\modules`: `russyn.sb`, `rsts.sb`
(Синодальный со Стронгом из swmail/RST — **главный русский эталон и
полнобиблейский приор**; лицензия не указана → только внутренне; текст —
другая редакция 1876, ~6 % реальных расхождений с `russyn`; сборка
воспроизводима: `module build --defs rstgit-defs.json`), `rstplus.sb`
(Синодальный + Стронг, ошибка импортёра — §9), `ru_rob.sb` (23
размеченные книги, греческие номера в формате uW `G15100`),
`eng-kjv2006.sb` (слова упакованы в `token_pack`), `engbsb.sb` (номера
eBible сдвинуты — не эталон), `oshb.sb`, `ugnt.sb`, `int_en.sb` (личный,
не распространять).

## 3. Форматы данных (проверенные факты)

**TAHOT** (табуляция, строки данных начинаются со ссылки):
`Eng (Heb) Ref & Type | Hebrew | Transliteration | Translation |
dStrongs | Grammar | Meaning Variants | Spelling Variants | Root
dStrong+Instance | Alternative Strongs+Instance | Conjoin word |
Expanded Strong tags`. Пример: `Gen.1.1#01=L | בְּ/רֵאשִׁ֖ית |
be./re.Shit | in/ beginning | H9003/{H7225G} | HR/Ncfsa | … |
H9003=ב=in/{H7225G=רֵאשִׁית=: beginning»first:1_beginning}`.
Ссылки — в английской нумерации, еврейская в скобках. Корень — в `{}`;
`/` разделяет морфемы; `H9xxx` — приставки/окончания/пунктуация;
`_A`, `_B` — повторы одного слова в стихе. Метка значения после `»` —
подзначение этого dStrong из TBESH (G→1, H→2…; исключение H0776: G=2,
H=1). ID людей и мест: `LORD@Gen.1.1-Heb`,
`Abram»Abraham@Gen.11.26-1Pe`. Метку значения несут 37 % корней в
Быт–Втор. Заголовок файла объясняет коды кетив/кре.

**TAGNT**: `Word & Type | Greek | English translation | dStrongs =
Grammar | Dictionary form = Gloss | editions | Meaning variants |
Spelling variants | Spanish translation | Sub-meaning | Conjoin word |
sStrong+Instance | Alt Strongs`. Пример `Mat.1.1#03=NKO | Ἰησοῦ
(Iēsou) | of Jesus | G2424G=N-GSM-P | Ἰησοῦς=Jesus/Joshua |
NA28+NA27+Tyn+SBL+WH+Treg+TR+Byz | … | Jesus»Jesus|Jesus@Mat.1.1`.
Буквы типа слова N/K/O — наличие в NA/KJV(TR)/других; `editions` —
список изданий.

**TBESH / TBESG**: `eStrong | dStrong (= связь, напр. "H0776G = in
Hebrew of") | uStrong | Hebrew/Greek | Transliteration | Morph | Gloss
| Meaning`. TBESH: 11 682 строки, 9 345 расширенных, 11 672 уточнённых
(4 340 с буквой). TBESG: 11 035 строк; диапазон НЗ G1–G5624 — 5 709
строк, 292 уточнённых с буквой. Источники Meaning в TBESG помечены
`(AS)`, `(ML)`, без пометки — STEPBible. **TBESH Meaning = сокращённый
BDB от Online Bible — нужно разрешение (вопрос 48).**

**OpenScriptures HebrewLexicon**: `AugIndex.xml` `<w aug="1254a">bxy</w>`
→ `LexicalIndex.xml` `<entry id="bxy">…<xref bdb="b.cw.aa" strong=…/>`
→ `BrownDriverBriggs.xml` `<entry id="b.cw.aa">` с `<sense n=…>`,
`<def>`, `<ref r="Gen.1.1">`, `<status>` (base 6 395, ref 2 312, made
2 123, done 560, new 453). Ключ сопоставления: расширенный номер TBESH
`H1254A` → aug `1254a` (буква строчная, без ведущих нулей). Совпадают
9 289 из 9 296; расхождения: 8106a/b, 8323a/b, 2428a, 1719c, 5867c.

**BSB tables** (`bsb_tables.tsv`, 23 колонки): Heb Sort, Greek Sort,
BSB Sort, Verse, Language, WLC/Nestle Base (с отметками изданий
TR/RP/WH/NE/NA/SBL), …, Translit, Parsing ×2, Str Heb, Str Grk
(классические номера), VerseId, Hdg, Crossref, Par, Space, begQ, BSB
version (английское слово/фраза), pnc, endQ, footnotes, End text.
Соответствие иногда по фразе («the heavens» ↔ одно слово).

**Clear Alignments** (JSON Scripture Burrito 0.3): `records[]` с
`source: ["o010010010012"]` (o/n + BB CCC VVV WWW P = слово MACULA +
часть), `target: ["01001001002"]` (BB CCC VVV WWW в TSV перевода),
`meta.process = manual`. TSV перевода `data/<lang>/targets/<ID>/*.tsv`:
`id, source_verse, text, skip_space_after, exclude, …`.
Беглая проверка RUSSYN: ВЗ — размечено 182 340 из 434 855 слов
(41,9 %), НЗ — 89 248 из 129 477 (68,9 %); **13–14 % размеченных
идентификаторов — знаки препинания**; Быт 1:1 верно, Быт 1:2 не сходится
→ замер F. Примечание: `data/catalog.tsv` в оригинале — указатель Git
LFS.

**ESV sqlite** (`esv/esv2016_strongs_step.sqlite`): `verses(id, book,
book_abbr, chapter, verse, text)`, `words(id, verse_id, seq, word_pos,
word, strongs)`, `unplaced(...)`. Номера без префикса, через запятую;
семизначные номера объяснены в `esv/README.md`. Значимые слова
размечены на 88,9 %, служебные — на 18 %.

## 4. Действующие решения (кратко по ADR 0025)

Ключ — уточнённый номер; сменные определения; основной — словарный
подстрочник; слой разметки в нумерации перевода с привязкой
id+хэш+разбиение; одно разбиение на слова в ядре; `conf` 0–10 везде;
конвейер: сначала без модели, модель в конце (выравнивание → проверка
→ сверка), агентом по главам, происхождение по главам; сначала порог
на английском; TTESV только по рабочим книгам; отложенные книги;
наполнение графа; закреплённые источники. Подробности — в ADR.

### 4.1 Шкала уверенности `conf` (0–10)

| Балл | Значение | Действие |
|---|---|---|
| 10 | Однозначно: все проверки сошлись, вариантов нет | автоматически |
| 9 | Очень уверенно: только различия формулировок | автоматически |
| 8 | Уверенно с оговоркой (многозначность, но значение подтверждено) | принять, пометка в данных |
| 7 | Скорее верно; часть проверок расходится | **«спорно»** |
| 6 | Возможно верно; есть правдоподобная альтернатива | «спорно» + альтернатива |
| 5 | Неясно; две равноценные версии | ручная проверка; показывается как спорное |
| 3–4 | Скорее неверно / нарушает правила | ручная проверка; по умолчанию скрыто |
| 0–2 | Ошибка или нет данных | не публикуется |

Всегда хранится вместе с `flags` (`polysemy`, `glossary_conflict`,
`sibling_clash`, `backtrans_mismatch`, `judge_low`, `name`,
`textual_variant`, `no_candidate`, `multi_candidate`…), `review`
(`auto|judge|human`), `source`, `notes`.

Сигналы: (1) совпадение независимых вариантов (два прогона или две
модели); (2) обратный перевод против английского толкования и метки
значения; (3) балл 0–10 независимой модели-оценщика по фиксированным
критериям; (4) правила (глоссарий, соседние значения различаются,
связанные uStrong статьи согласованы, синодальные формы имён, номер
есть в стихе и в лексиконе). Черновое правило объединения (подобрать на
рабочих книгах, заморозить до отложенных — вопрос 52): начать с балла
оценщика; −2, если варианты расходятся; −2, если обратный перевод не
совпал; не выше 4 при нарушении жёсткого правила; не выше 7 при
`polysemy` без подтверждения значения; решения разметки без модели с
апостериорной вероятностью eflomal ≥ 0,9 и согласием словаря
соответствий начинаются с 9. Калибровка (доля ошибок по уровням,
монотонно) измеряется в фазе 7.

### 4.2 Отложенные книги

Руфь, Иона, Ездра, Пс 1–41, Ис 40–55, Марк, Филиппийцам, Иакова,
Откр 1–5. Не входят во вход ни в каком виде (ни словарь соответствий,
ни промпты, ни подстройка правил). Всё остальное — рабочие книги.

### 4.3 Лицензионные правила

Лексикон и опорный слой — только входы CC BY / CC0 / общественное
достояние. TTESV (NC) — только как словарь соответствий по рабочим
книгам → лицензия итогового слоя `CC BY-NC`. ru_rob (CC BY-SA) и RST+
(неясно) — только эталоны. Текст ESV не покидает `STUDYBIBLE_DATA`.
Каждый производный модуль несёт атрибуцию (STEPBible «STEP Bible,
www.STEPBible.org»; OpenScriptures; MACULA «MACULA … Linguistic
Datasets, available at github.com/Clear-Bible/…»; авторы Clear
Alignments) и список наших изменений.

Аудит зависимостей MACULA (13.10.2026, подробности —
`sources/strongs/legal/marble-license-analysis.ru.txt`):

- Nestle1904: текст, глоссы (Berean), морфология/леммы/номера — общ.
  достояние; XML-разметка CC BY-SA → можно использовать при
  необходимости с атрибуцией, но тогда производный модуль (или его
  часть) лицензируется под CC BY-SA. Сейчас не используем: опора —
  TAHOT/TAGNT.
- SBLGNT (Faithlife) — CC BY 4.0.
- Собственные данные Clear (синтаксис, референты, семантические рамки,
  синонимы, mappings) — CC BY 4.0 → при желании допустимы в графе
  знаний с атрибуцией.
- MARBLE `@ln`/`@domain` и SDBH `@sdbh` — «used with permission» UBS,
  объём передачи прав не оговорён → используем только для внутреннего
  расчёта баллов; метки из MACULA в модули не включаем.
- **Легальный канал публикации есть** (13.10.2026): тот же материал
  официально опубликован самой UBS под CC BY-SA 4.0 —
  `ubsicap/ubs-open-license` → `ubs-dictionaries` (греческий =
  Louw–Nida SDGNT, иврит = SDBH). Коды доменов совпадают с `@ln`
  MACULA (формат «33.98»). Публикуемые метки/значения доменов — только
  отсюда, часть модуля тогда помечается CC BY-SA.
- На semanticdictionary.org есть русская версия MARBLE — проверить в
  фазе 8 как источник русских названий доменов и значений.

## 5. Фазы, задачи, результаты, приёмка

Порядок: 0 → 1 → (2, 3, 3b, 5 параллельно) → 4 → 6 → 7 (порог) → 8.
Прогресс — в `docs/ROADMAP.md` (локально), решения — в
`docs/DECISIONS.md`.

### Фаза 0 — документы (сделано 13.10.2026)

ADR 0025, дополнение ADR 0024, DECISIONS, SPEC, OPEN-QUESTIONS (48–53),
ROADMAP, этот спек, данные закреплены.

### Фаза 1 — замеры (инструменты: `tools/strongs/measure/*.py`)

Каждый замер пишет `STUDYBIBLE_DATA/work/strongs/measure/<X>.json` и
краткое резюме в Markdown для пользователя.

- **A. Классический номер → уточнённый.** Для каждой пары (стих,
  классический номер) из BSB tables, KJV и ESV: сколько уточнённых
  номеров в соответствующем стихе TAHOT/TAGNT имеют такую основу. Доли:
  ровно один / несколько / ни одного. Ожидание: в основном один.
- **B. Согласие эталонов.** Пословное согласие на общих стихах: BSB
  tables ↔ ручная BSB от Clear ↔ KJV ↔ TTESV (для TTESV — рабочие
  книги). Сравнение на уровне классических номеров по каждому слову
  после проекции эталонов на одно разбиение по смещениям символов.
  Отдельно значимые/служебные, ВЗ/НЗ. Это потолок для порога.
- **C. Нумерация стихов.** Ссылки TAHOT/TAGNT ↔ `eng` ↔ `rsc` через
  `Versification::convert`; список неоднозначных стихов (кандидаты в
  `verse_map`).
- **D. Расхождения исходных текстов.** Доля слов эталонов BSB/KJV,
  номеру которых нет слова в опорном слое для издания перевода
  (`editions` TAGNT; кетив/кре TAHOT).
- **E. Греческие значения.** Покрытие колонки «Sub-meaning» TAGNT и
  домены Louw–Nida MACULA; решить источник греческих значений
  (вопрос 51).
- **F. Качество RUSSYN от Clear.** Выяснить, почему размеченные
  идентификаторы попадают на пунктуацию (переразбить Синодальный
  разными способами, сравнить с TSV, проверить редакции текста);
  вручную просмотреть 100 стихов; если исправимо — измерить согласие с
  RST+ (после исправления импортёра) и ru_rob. Решить: строить слой
  Синодального напрямую или нет (вопрос 50).
- **G. Соответствие слов MACULA ↔ TAHOT/TAGNT.** Детерминированное
  сопоставление по стиху через лемму/номер/порядок (с обеих сторон
  WLC; SBLGNT ⊂ TAGNT). Покрытие и конфликты.

Приёмка: все семь отчётов есть и пересказаны пользователю; вопросы
50/51 закрыты.

### Фаза 2 — лексикон `strongs-step` — **готово 13.10.2026 (v0.2.0)**

Статус: собран и принят — см. `report-phase2.md` в
`work/strongs/lexicon/`. Примечание: реализовано как Python-конвейер
`tools/strongs/lexicon/` (`step01`…`step07`, одобрено пользователем
как временный компромисс; контракт спека — модуль и схема ниже, а не
язык эмиттера — порт в Rust CLI позже, если станет продуктовой
фичей). Решения по ходу: базовые слои ключом базы, джойн через
`lex_base`; alignments Aquifer — списки кандидатов → привязка по
первому `strongs-number`/majority vote; `features` перечисляет
свои таблицы (`entries,lex,lex_def,lex_base,morph`). 12 ключей
помечены `ambiguous-base` на проверку; TBESH `Meaning` не
использовался.

Перепроверка после сборки (тот же день): дедуп UBS-значений
(повторы глоссов между `BaseForms`) → `lex_def` 54 959; `G21370`
(единственная строка без глосса — LXX-запас) помечен
`(no STEP gloss)`; карточки под ключом базы теперь с headword =
лемма семейства (`אֱלֹהִים` для `H430`). Базы `lex_base` без строки
в `lex` — по дизайну (база — ключ нормализации семейства, а не
dStrong-ключ). На экспертную проверку: 12 ключей `ambiguous-base`;
редкие промахи привязки `bdb-aramaic` по majority vote (замечен
один у `H9003`).

Подкоманда CLI `studybible module lexicon-step <папка stepbible>
<папка oshb-lexicon> <папка abbott-smith> -o strongs-step.sb` (Rust, в
`apps/studybible-cli`, образец — `src/bin/xref_layer.rs`; запись —
`ModuleWriter` в `crates/studybible-store/src/module.rs`).

Схема (необязательные таблицы; стандартную `entries` тоже заполнить
для общего интерфейса и FTS):

```
lex(key TEXT PRIMARY KEY,    -- dStrong 'H5414H'
    estrong TEXT, base TEXT, -- 'H5414', 'H5414'
    lang TEXT,               -- 'en'
    lemma, xlit, pos, gloss, -- краткое толкование Tyndale
    sense_label,             -- '2_put;_set' (из TAHOT)
    sense_domain,            -- код домена из ubs-dictionaries (CC BY-SA); метку показывать только с этой пометкой
    relation, related,       -- 'aramaic_of'|'name_of'|'combination', 'H0006'
    ustrong, source,
    conf INTEGER, flags TEXT, review TEXT)   -- у английской основы conf=10
lex_def(key, lang, def, def_source, def_license, conf, flags, review)
lex_base(base, key)          -- H5414 → H5414G…Q
morph(code, lang, short, long, conf)        -- TEHMC/TEGMC
meta: kind=dictionary, features=entries, id=strongs-step, license, attribution, sources
```

Определения: иврит — BDB от OpenScriptures по цепочке из §3 (схему
`<sense>` выводить нумерованным текстом, `<ref>` сохранять) плюс
опционально полная BDB из `bdb-full` (`def_source='bdb-full'`) и
статьи UBS из `ubs-dictionaries` (`def_source='ubs-sdbh'`, часть
модуля CC BY-SA); арамейский — `bdb-aramaic` (CC0, Aquifer);
`bdb-hebrew-aq` — третья редакция BDB, её alignments дают привязку
значений к стихам; имена — биографии TBESH/TIPNR (кросс-ворк ACAI
на TIPNR помогает); греческий —
Abbott-Smith + тексты STEPBible + значения UBS Greek
(`def_source='ubs-sdgnt'`, коды LEXEntryCode = Louw–Nida); 76
статей ML в G1–G5624 + G6000–6099 заменить Abbott-Smith, где он есть,
иначе только кратким толкованием (`def_source='gloss-only'`). Строки
TBESH Meaning (`def_source='OLB-abridged-BDB'`) добавлять **только при
разрешении (вопрос 48)**.

Отдельный необязательный `lsj.sb` из TFLSJ (`license` «CC BY-SA
(производное от LSJ Perseus)»).

Приёмка: у каждого уточнённого номера из TAHOT/TAGNT есть строка `lex`;
у каждой строки есть краткое толкование; у каждого встречающегося кода
морфологии есть строка `morph`; `module check` проходит; модульный тест
на 10 известных ключах (H0776G/H, H5414G/H, H1254A, H0430G, G2424G,
G4151G/H, H9003, G3056).

### Фаза 3 — опорный слой `step-orig` — **готово 2026-10-13**

Собрано на Python в `tools/strongs/orig/` (3 шага:
`step01_parse.py` TAHOT+TAGNT → `orig-words.jsonl`,
`step02_macula.py` WLCM/SBLGNT → `mid`, `step03_build.py` → .sb).
Конкретная схема спана зафиксирована в ADR 0025 §3: один блок `p` на
стих, **один `w`-спан на морфему**, текст спана — контекстный
английский глосс; атрибуты `gr`/`strong`/`morph`/`lemma`/`wid`
(+`typ`/`ed`/`sns`/`eid`/`conj`/`mid`). Итог: 31 210 стихов,
679 155 спанов, `mid` 512 853 (75,5 %), `eid` 45 131, `sns` 80 345;
`module check` чист; отчёт `work/strongs/orig/report-phase3.md`.
Результат: `work/strongs/orig/step-orig.sb` (~193 MB без упаковки;
блоб-пак — следующая оптимизация).

### Фаза 3b — выгрузка для этапа 1 мегаэнциклопедии — **готово 2026-10-13**

Собрано на Python в `tools/strongs/knowledge/step01_build.py`.
Каркас — ACAI (`primary_id` = id сущности): 5 700 сущностей,
62 548 имён, 12 527 отношений, 114 214 `verse_mentions` в
координатах `eng` (USFM-код книги, `seg=0`). eid нормализуется к
`Имя@ПерваяСсылка`; `entities.strongs` — по трём каналам (eid→
step-orig, lex-name, леммы→lex-core), у 89 % сущностей есть номера.
Статьи Aquifer (OBD/FIA/Biblica) в `metadata.articles`, ru-имена —
kind='biblical'. Лицензия CC BY-SA 4.0. Отчёт —
`work/strongs/knowledge/report-phase3b.md`.

### Фаза 4 — английские подстрочники и чтение слоёв в приложении — **готово 14.10.2026**

Реализовано в `apps/studybible-flutter/rust/src/api/module.rs` и
`apps/studybible-flutter/lib/`:
- Контекстный подстрочник (колонка перевода TAHOT/TAGNT в `step-orig.sb`)
  и словарный подстрочник (`InterlinearMode.dictionary`: глосс `dStrong`
  + код морфологии через `@dict_glosses:<book>` из `strongs-step.sb`) с
  сегментным переключателем «Контекстный / Словарный».
- Автоматическое наложение слоя Стронга (`inject_layer_strongs`) в
  `chapter_doc`: проверка `target_id` + `target_hash` + `tokenizer="w1"`,
  приоритетная замена старых сдвинутых `strong="..."` на `dStrong`/
  `conf`/`flags`/`ref` со сквозной нумерацией `w1` через поэтические
  блоки и баннер `layer_mismatch` при расхождении хеша.
- Тап/долгое нажатие по слову открывает расширенную карточку (`@lex:...`
  + `@entity:...`): `strongs-step.sb` (`lex`, `lex_def` по `dStrong` и
  `base`, `morph`, `sense_domain` с пометкой CC BY-SA), контекстное
  значение `sns` из `step-orig.sb` по `ref` и карточку сущности
  `knowledge.sb` с кликабельными связями.
- Проверено сквозным тестом `test/bridge_test.dart` на Быт 1, Пс 23,
  Ин 1; `flutter analyze` и `cargo clippy -D warnings` чисты.

### Фаза 5 — формат слоя, разбиение на слова в ядре, приложение, исправления импортёров — **сделано 13–14.10.2026**

Реализовано (см. DECISIONS «таблица `links` и токенизатор `w1`»):
- `studybible_core::text::words(text) -> Vec<&str>` (`w1`,
  `WORDS_VERSION`): резка по пробелам, краевая пунктуация снимается,
  внутренняя хранится (`don't`, `son-in-law`, `3:00`), токены без
  букв/цифр индекса не получают. CLI `studybible tokenize
  <module.sb>` → JSONL `_meta` + `{book, chapter, verse, words:[…]}`
  на стих.
- `links(book_id, chapter, verse, word, ref, strong, conf, flags,
  source)` в SCHEMA + `Link`/`add_link`/`links()`/`has_links()`;
  привязка meta `target_id`/`target_hash`/`tokenizer`.
- Исправления импортёров сделаны: `attach_strong` дописывает
  `strong="H1254" strong="H853"` в тот же `w`-спан (было: брался
  последний тег); `token_of`/`attr_all` собирает все значения
  `strong=`/`morph=` через пробел (было: только первое — 30 041
  спан rsts).
- Flutter `normalizeStrong`: `H0029G` (+канон `H29G`), uW `G15100`,
  списки через пробел; поиск сперва по исходному ключу.
- Наложение слоя в `chapter_doc` (conf 5–7 → волнистое акцентное
  подчёркивание «спорно», `aux` → приглушённый пунктир, баннер
  `layer_mismatch` при несовпадении хеша) — сделано в Фазе 4 (14.10.2026).
- Пилот `engbsb-strongs.sb` через `apps/studybible-cli/src/bin/
  strongs_layer.rs` (bsb_tables.tsv → 706 502 связи, `conf=10`;
  пропуски в `bsb-strongs.misses.tsv`; `module check` чист).
- **v0.4.0 (Фаза 5b — заменяет пилот, v2 и v0.3.0):**
  `work/strongs/layers/engbsb-strongs.sb` через
  `tools/strongs/layers/step_clear_bsb.py` — настоящий dStrong из
  ручных выравниваний Clear (`WLCM-BSB`, `SBLGNT-BSB`, `BGNT-BSB` для
  Рим 16:25–27) через `step-orig.mid` (606 231 прямой `mid` в
  `step-orig` v0.2.0), масоретский запасной `wid`, фолбэк
  `bsb_tables`+`step-orig` (`PSA *:0`, `NEH 7:68` и 1 006 слов с
  редакционными отличиями) и внутригрупповое расщепление (`split_group`
  на `head` / `aux` / `added`). **728 034 связи (100,00 % слов `w1`)**;
  `conf=10`: 723 139 (99,33 %), `conf=9`: 3 294, `conf=8`: 1 594,
  `conf=4` (`unresolved`): 7 слов; слов с 1 номером `dStrong`: 582 515
  (80,0 %); канал разбора `diff` (`engbsb-strongs.diffs.tsv`, 8 475
  лексических расхождений).
  NB: `bsb_tables.tsv` несёт классические номера, не dStrong.
Приёмка выполнена: clippy `-D warnings` чист, тесты зелёные,
регрессионные тесты на оба исправления.

### Фаза 6 — конвейер разметки (`tools/strongs/pipeline/`) — **готово 14.10.2026**

Реализовано в `tools/strongs/pipeline/` (`priors.py`, `contour1.py`,
`contour2.py`, `build_layer.py`) + скиллы в `.devin/skills/` и
`tools/strongs/skills/` (`strongs-verse-align`, `strongs-review`,
`strongs-chapter-reconcile`):
- `studybible tokenize --with-spans <module.sb>` выгружает пословные
  стили и атрибуты `w1` как из `spans`, так и из `span_pack`.
- `priors.py` строит `work/strongs/pipeline/priors_en.json` строго на
  **рабочих книгах** (без отложенных книг §4.2): 359 замен `form_alias`,
  19 570 связей `classic -> dStrong` и 23 217 словарных приоров.
- `contour1.py` + `contour2.py` + `build_layer.py` поддерживают режимы
  `--mode assisted` (подъём классических номеров + `\add` + `form_alias`
  + служебные морфемы `H9xxx`/`G3588`) и `--mode blind` (выравнивание
  «голых» слов `w1` по глоссам `step-orig`/`strongs-step` и приорам
  рабочих книг), разрешают полисемию, проводят сверку по главе,
  сохраняют квитанции глав `runs/<target>/<BOOK>.<ch>.json` с `--resume`
  и собирают `.sb`-слои (`eng-kjv2006-strongs.sb`: 790 715 связей,
  100 % слов `w1`, `module check` чист).

| Шаг | Что делает | Модель |
|---|---|---|
| 1 | слова через `studybible tokenize` | нет |
| 2 | соответствие стихов перевода → `eng` | нет |
| 3 | кандидаты = слова опорного слоя стиха(ов), отфильтрованные по изданию перевода (BSB/ASV эклектичный, KJV — TR…) | нет |
| 4 | eflomal по всей Библии: слова/леммы перевода ↔ уточнённые номера, вероятности | нет |
| 5 | словарь соответствий: BSB tables, TTESV (только рабочие книги) для английского; свои толкования для других языков | нет |
| 6 | объединение → решение + предварительный `conf` | нет |
| 7a | **выравнивание** нерешённых слов (скилл `strongs-verse-align`) | да |
| 7b | **независимая проверка** стиха (скилл `strongs-review`) → 0–10 | да |
| 7c | **сверка по главе** (скилл `strongs-chapter-reconcile`) | да |
| 8 | проверка (номер ∈ стих ∧ лексикон), итоговый `conf`, сноски, статистика | нет |

Выполняется **агентом по главам**. На каждую главу пишется
`STUDYBIBLE_DATA/work/strongs/runs/<target>/<BOOK>.<ch>.json`: модель и
версия, версия и хэш правил, дата, решения по словам с
`conf/flags/source`, квитанции проверки. Продолжение с места остановки:
пропускать главы, у которых запись есть и хэш правил совпадает.
Правила начать с
`asv-alignment/config/alignment-instructions-{hebrew,greek}.md`.

### Фаза 7 — проверка на английском (порог) — **пройден 14.10.2026**

Замерено на 9 отложенных корпусах (`RUT`, `JON`, `EZR`, `PSA 1–41`,
`ISA 40–55`, `MRK`, `PHP`, `JAS`, `REV 1–5`) скриптом
`tools/strongs/pipeline/evaluate_gate.py` (отчёт —
`work/strongs/report-phase7-en-gate.md`, JSON —
`work/strongs/pipeline/gate_phase7.json`, заморожено `N = 2,0 п.п.`,
вопрос 52 закрыт):
- **BSB Режим А (`engbsb-strongs.sb` v0.4.0 против `bsb_tables`):** F1
  значимых слов = **97,52 % ВЗ / 96,73 % НЗ** (+2,32 п.п. / +1,33 п.п.
  выше потолка согласия эталонов `B = 95,2 % / 95,4 %`), служебных =
  **96,98 % ВЗ / 96,78 % НЗ**, имена собственные = **98,90 %**
  (`n = 2 372`).
- **KJV Режим Б (`eng-kjv2006-strongs.sb` v0.1.0 против KJV +
  `step-orig`):** F1 значимых слов = **100,0 % ВЗ / 99,99 % НЗ**
  (точность `dStrong` **99,97 % ВЗ / 99,99 % НЗ**), имена собственные =
  **99,96 %** (`n = 2 380`).
- **Слепой Режим В (базовая линия без входных тегов, только приоры
  рабочих книг):** F1 значимых слов = **82,10 % ВЗ / 80,41 % НЗ**, имена
  собственные = **97,04 %**, точность на срезе `conf=10` (63 % слов) =
  **94,32 %**, строго монотонная шкала ошибок по `conf = 10 → 9 → 8 → 7`
  (`5,68 % < 26,24 % < 32,96 % < 64,47 %`). **Порог пройден — открыт
  переход к Фазе 8 (русский язык).**

| Перевод | Эталон | Разрешённые входы |
|---|---|---|
| BSB (главный) | BSB tables; ручная BSB от Clear | TTESV по рабочим книгам |
| KJV | собственная разметка | BSB tables, TTESV по рабочим книгам |
| ESV | TTESV по отложенным книгам | BSB tables |
| ASV (сравнение) | подстрочник ASV от OpenBible | как для KJV |

Метрики: точность/полнота/F1 по парам (слово, классический номер) и
(слово, уточнённый номер); значимые и служебные слова; ВЗ/НЗ; точность
уточнённых номеров на именах по TIPNR; **калибровка** (доля ошибок на
каждом уровне `conf`); доля слов, ушедших модели; токены/затраты на
главу; расхождения исходных текстов — отдельным списком. Эталон
проецируется на слова `w1` по смещениям символов. Порог (сначала
заморозить N, вопрос 52): F1(значимые, отложенные) ≥ согласие эталонов
(B) − N; имена ≥ 95 %; калибровка монотонна. **Не прошли — русского
нет.**

### Фаза 8 — русский (после порога) — **готово 14.10.2026**

Реализовано в `tools/strongs/pipeline/prep_rlob.py`,
`tools/strongs/pipeline/build_ru_layers.py`,
`tools/strongs/lexicon_ru/build_lexicon_ru.py` и
`tools/strongs/knowledge/step02_ru_names.py`:
- **8.0 Современные открытые русские корпуса (`door43-ru`, CC BY-SA
  4.0):** скачаны `ru_rlob` (v13.0, 31 книга), `ru_rsob`, `ru_tw` (1 018
  русских статей Translation Words), `ru_twl` и `ru_tn`; собран модуль
  `modules/ru_rlob.sbz` и чисто пересобран `modules/ru_rob.sbz` (с
  сохранением приставок `\zaln-s` и нормализацией 5-значных кодов uW
  `G15100 → G1510`).
- **8.1 `strongs-step-ru.sbz` (`v0.1.0`):** 22 743 записи `dStrong` в
  `lex` на современном русском языке (архаизмы XIX века вроде *мытарь,
  выя, чресла, наипаче* заменены современными эквивалентами с пометкой
  `(в Син.: …)`), 3 190 русских расшифровок `morph` и 63 950 записей
  `lex_def` (`door43-tw-ru`, `corpus-ru` по RLOB/РОБ/Синодальному и слои
  UBS SDBH/SDGNT + OSHB).
- **8.2 Русский словарный подстрочник и карточки в приложении:**
  Rust-мост (`find_lex_module`) и Flutter автоматически используют
  `strongs-step-ru.sbz` при `settings.lang == 'ru'`.
- **8.3 Три русских накладных слоя `dStrong`:**
  - `russyn-strongs.sbz` (570 826 связей, 100 % слов `w1` модуля
    `russyn.sb`, сдвиги `rsc ↔ eng` по `verse_map.json`);
  - `ru_rlob-strongs.sbz` (202 958 связей, 100 % слов `w1` модуля
    `ru_rlob.sb`);
  - `ru_rob-strongs.sbz` (557 946 связей, 100 % слов `w1` по всем 66
    книгам `ru_rob.sb`, включая 43 книги ВЗ без исходного `\zaln`).
- **8.4 Русские имена в `knowledge.sbz`:** добавлено 3 488 синодальных
  (`kind='synodal'`) и современных (`kind='biblical'`) русских форм имён
  в `entity_names`. Все модули проходят `studybible module check`.

- **8.1** `strongs-step-ru.sb` через скилл `lexicon-translate`: краткие
  толкования уточнённых номеров + метки значений, таблица морфологии,
  глоссарий; имена — последними (из 8.3, синодальные формы); полные
  определения — только после вопроса 48 (переводятся один раз из
  выбранного источника). У каждой строки есть `conf`. Экспертная
  выборка по частотности + все строки с `conf ≤ 7`.
- **8.2** Русский словарный подстрочник (без модели): опорный слой +
  русские толкования + русская морфология; спорные места видны.
- **8.3** Синодальный (`russyn`): конвейер фазы 6; эталоны —
  **`rsb-aquifer` (ручное пословное выравнивание RUSSYN→WLCM/SBLGNT,
  234 908 записей, все 66 книг, CC0 — публикуемый)** и **`rsts`
  (66 книг со Стронгом из swmail/RST; номера читать из `spans.attrs`
  до починки `token_of`; лицензия не указана — только внутренне)** +
  исправленный RST+ + ru_rob; приор «слово → классический номер»
  из `rsts` и выравнивания Aquifer. RUSSYN от Clear исключён
  (сломан, замер F). Редакции текста расходятся (~6 % у rsts —
  Aquifer-редакцию сверить отдельно), на расходящихся стихах — флаг
  редакции, в оценку не входят. Экспертная выборка 200–300 стихов.
- **8.4** `entity_names` (ru) мегаэнциклопедии из слоя Синодального.

Следующие языки: толкования + морфология с `conf`, словарный
подстрочник, конвейер на основном переводе, эталон — ручная разметка
Clear, где она есть (fra LSG, spa RV09, por, arb, hin, hau…).

## 6. Скиллы (создаются при начале фаз 6/8)

Скилл = файл инструкций + скрипты. Для Devin — в
`.devin/skills/<name>/SKILL.md`; для других агентов тот же текст — в
`tools/strongs/skills/<name>.md`. Промпты и критерии **замораживаются
до** замера на отложенных книгах; изменение повышает версию правил.

### 6.1 `strongs-verse-align` (шаг 7a)

Вход на главу (JSON): по каждому стиху — пронумерованные слова
перевода (`w1`), кандидаты (адрес, слово, транслитерация, уточнённый
номер, толкование, метка значения, морфология, издания), текущие
предложения без модели с предварительным `conf`, правила
выравнивания. **Без эталона.** Английский текст-подсказка — только для
неанглийских переводов и только из источников CC BY/CC0/общ.
достояние (BSB) — текста ESV в промптах для публикуемых слоёв нет.
Схема ответа: `{verse, links:[{word, refs:[address…] | [], role:
"head"|"part"|"added", conf_self:0-10, note}]}`. Жёсткие правила:
ссылки только из кандидатов стиха; каждый кандидат либо связан, либо
помечен `untranslated` с причиной; одно слово перевода может связываться
с несколькими словами оригинала (фразы) и наоборот.

### 6.2 `strongs-review` (шаг 7b; также оценщик для 8.1)

Независим от 6.1 (другая модель или свежий контекст). Вход: стих,
кандидаты, предложенные связи (или предложенный перевод статьи
лексикона). Ответ `{item, score:0-10, problems:[flag…], alternative}`.
Критерии = таблица §4.1; любой балл ≤ 7 обосновывается.

### 6.3 `strongs-chapter-reconcile` (шаг 7c)

Вход: все решения главы + результаты проверки. Задачи: найти
несогласованную обработку одного слова/оборота, предложить изменения
правил (записываются с новой версией правил), вернуть стихи в очередь.
Ответ: список изменённых связей с причинами + предлагаемые правки
правил.

### 6.4 `lexicon-translate` (фаза 8.1, любой язык)

Пакет ≈ 50 статей, сгруппированных по корню/uStrong. Вход: ключ, лемма,
английское толкование, метка значения, толкования соседних значений,
определение (из выбранного источника), глоссарий языка, правило для
имён. Ответ по статье: `{key, gloss, def?, alt?, conf_self, flags,
note}`. Затем сравнение двух вариантов, обратный перевод, оценщик
`strongs-review`, правила → итоговый `conf` (§4.1).

## 7. Известные факты и числа (для ориентира)

- Согласие наборов номеров по стиху ESV и русских переводов: ru_rob ВЗ
  92,8 % / НЗ 82,3 % (покрытие набора ESV); RST+ ~79 %. BSB (eBible)
  — всего 69 %.
- Импортёр RST+ теряет номера у 6,8 % размеченных слов.
- BDB от OpenScriptures против TBESH Meaning: TBESH полнее примерно у
  половины обычных слов (схемы подзначений), BDB длиннее в 52 %
  (полные статьи, 2 878 со ссылками на стихи); у имён богаче TBESH
  (биографии STEPBible).
- Подстрочник ASV от OpenBible: вся Библия ≈ 2,5 млрд токенов, ~$300 по
  подпискам (по прейскуранту ≈ $7 800); эталон в промптах мешал.
- Репозиторий STEPBible обновляется почти ежедневно — перезакреплять
  осознанно и со сравнением изменений.

## 8. Открытые вопросы

См. `docs/OPEN-QUESTIONS.ru.md` 48–53 (разрешение Online Bible,
лицензии ML/MARBLE, качество RUSSYN, греческие значения, числа порога,
будущие данные STEPBible).

## 9. Где что в коде

- Запись модулей: `crates/studybible-store/src/module.rs`
  (`ModuleWriter`); примеры слоёв: `apps/studybible-cli/src/bin/
  xref_layer.rs`, `strongs_layer.rs` (писатель таблицы `links`);
  CLI: `apps/studybible-cli/src/main.rs` (`tokenize` — слова `w1`).
- Версификация: `crates/studybible-core/src/versification.rs`
  (`convert`, `convert_mapped`); токенизатор `w1`:
  `crates/studybible-core/src/text.rs` (`words`, `WORDS_VERSION`).
- Исправлено 13.10.2026 (есть регрессионные тесты):
  `attach_strong` MyBible (подряд `<S>` сливаются в один `w`-спан);
  `token_of`/`attr_all` (все `strong=`/`morph=` собираются через
  пробел — 30 041 спан rsts с несколькими номерами сохраняет номера;
  кодек `token_pack` не тронут).
- Лексикон во Flutter: `apps/studybible-flutter/lib/lexicon.dart`
  (`normalizeStrong`: dStrong `H0029G`, uW `G15100`, списки;
  логика наложения, которой пользуется словарь Цыганкова).
- Пример записи модуля на Python (схема + `content_hash`):
  `scripts/build-interlinear.py`.
- Загрузка данных: `scripts/fetch-data.ps1` (`-Only`, `dest`, `files`),
  `data/sources.json`.
