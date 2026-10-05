/// Каталог книг (короткие русские имена + группа) и загрузка модулей.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'models.dart';
// Мост к данным: на нативных платформах — Rust-ядро через ffi,
// на web — sqlite3.wasm читает те же .sb из web/modules/,
// фоллбэк — предвыгруженные JSON-ассеты.
import 'native_bridge_stub.dart'
    if (dart.library.html) 'native_bridge_web.dart'
    if (dart.library.io) 'native_bridge_io.dart';
import 'state.dart';
import 'theme.dart';

/// Код → (короткое имя, группа). Порядок = канонический (66 книг).
const List<(String, String, BookGroup)> kCatalog = [
  ('GEN', 'Бт', BookGroup.torah),
  ('EXO', 'Исх', BookGroup.torah),
  ('LEV', 'Лв', BookGroup.torah),
  ('NUM', 'Чс', BookGroup.torah),
  ('DEU', 'Вт', BookGroup.torah),
  ('JOS', 'ИсН', BookGroup.hist),
  ('JDG', 'Сд', BookGroup.hist),
  ('RUT', 'Рф', BookGroup.hist),
  ('1SA', '1См', BookGroup.hist),
  ('2SA', '2См', BookGroup.hist),
  ('1KI', '1Цр', BookGroup.hist),
  ('2KI', '2Цр', BookGroup.hist),
  ('1CH', '1Лт', BookGroup.hist),
  ('2CH', '2Лт', BookGroup.hist),
  ('EZR', 'Езд', BookGroup.hist),
  ('NEH', 'Не', BookGroup.hist),
  ('EST', 'Эсф', BookGroup.hist),
  ('JOB', 'Иов', BookGroup.poet),
  ('PSA', 'Пс', BookGroup.poet),
  ('PRO', 'Пр', BookGroup.poet),
  ('ECC', 'Эк', BookGroup.poet),
  ('SNG', 'Псн', BookGroup.poet),
  ('ISA', 'Иса', BookGroup.majp),
  ('JER', 'Иер', BookGroup.majp),
  ('LAM', 'Пл', BookGroup.majp),
  ('EZK', 'Иез', BookGroup.majp),
  ('DAN', 'Дан', BookGroup.majp),
  ('HOS', 'Ос', BookGroup.minp),
  ('JOL', 'Ил', BookGroup.minp),
  ('AMO', 'Ам', BookGroup.minp),
  ('OBA', 'Авд', BookGroup.minp),
  ('JON', 'Ион', BookGroup.minp),
  ('MIC', 'Мх', BookGroup.minp),
  ('NAM', 'На', BookGroup.minp),
  ('HAB', 'Авв', BookGroup.minp),
  ('ZEP', 'Сф', BookGroup.minp),
  ('HAG', 'Аг', BookGroup.minp),
  ('ZEC', 'Зх', BookGroup.minp),
  ('MAL', 'Мл', BookGroup.minp),
  ('MAT', 'Мф', BookGroup.gosp),
  ('MRK', 'Мк', BookGroup.gosp),
  ('LUK', 'Лк', BookGroup.gosp),
  ('JHN', 'Ин', BookGroup.gosp),
  ('ACT', 'Де', BookGroup.acts),
  ('ROM', 'Рм', BookGroup.paul),
  ('1CO', '1Кр', BookGroup.paul),
  ('2CO', '2Кр', BookGroup.paul),
  ('GAL', 'Гл', BookGroup.paul),
  ('EPH', 'Эф', BookGroup.paul),
  ('PHP', 'Фп', BookGroup.paul),
  ('COL', 'Кл', BookGroup.paul),
  ('1TH', '1Фс', BookGroup.paul),
  ('2TH', '2Фс', BookGroup.paul),
  ('1TI', '1Тм', BookGroup.paul),
  ('2TI', '2Тм', BookGroup.paul),
  ('TIT', 'Тит', BookGroup.paul),
  ('PHM', 'Фм', BookGroup.paul),
  ('HEB', 'Евр', BookGroup.paul),
  ('JAS', 'Иак', BookGroup.cath),
  ('1PE', '1Пт', BookGroup.cath),
  ('2PE', '2Пт', BookGroup.cath),
  ('1JN', '1Ин', BookGroup.cath),
  ('2JN', '2Ин', BookGroup.cath),
  ('3JN', '3Ин', BookGroup.cath),
  ('JUD', 'Иуды', BookGroup.cath),
  ('REV', 'Отк', BookGroup.rev),
];

/// Код → короткое имя.
final Map<String, String> kShortName = {for (final e in kCatalog) e.$1: e.$2};

/// Код → группа.
final Map<String, BookGroup> kBookGroup = {
  for (final e in kCatalog) e.$1: e.$3,
};

/// Разделы сетки.
const kSectionOt = 'ЕВРЕЙСКО-АРАМЕЙСКИЕ ПИСАНИЯ';
const kSectionNt = 'ХРИСТИАНСКИЕ ГРЕЧЕСКИЕ ПИСАНИЯ';
// Секция книг модуля вне каталога 66 (второканонические и пр.).
const kSectionOther = 'НЕКАНОНИЧЕСКИЕ КНИГИ';
const int kNtFirstIndex = 39; // 'MAT'

/// Индекс книги в каноне (для переходов через границы книг).
int bookIndexOf(String code) => kCatalog.indexWhere((e) => e.$1 == code);

/// Известные модули: названия для UI по id.
/// Наполняется сканом .sb-файлов каталога данных (нативные платформы);
/// JSON-ассеты остаются фоллбэком там, где .sb нет (и единственным
/// источником на web — см. native_bridge_stub.dart).
/// Личные модули (-ru и др.) сюда НЕ вписываются: они появляются
/// в списке только когда их .sb реально найден в каталоге данных —
/// иначе id показывался бы на публичной web-сборке и не открывался.
final Map<String, String> kModules = {
  'russyn': 'Синодальный перевод',
  'ru_rob': 'Русская открытая Библия',
  'engwebp': 'World English Bible',
  'kjv2006': 'KJV 2006 (Стронг)',
  'englsv': 'Literal Standard Version',
  'engbsb': 'Berean Standard Bible',
  'oshb': 'Еврейская Библия (OSHb)',
  'ugnt': 'Греческий НЗ (UGNT)',
};

/// Пометки модулей в списке: критические тексты и оригиналы
/// выделяем отдельно от обычных переводов.
const Map<String, String> kModuleTags = {
  'englsv': 'критический текст · YHWH · Стронг',
  'engbsb': 'критический аппарат · Стронг',
  'oshb': 'оригинал · иврит · Стронг',
  'ugnt': 'оригинал · греческий · Стронг',
  'eng-kjv2006': 'номера Стронга',
  'ru_rob': 'CC BY-SA 4.0',
  'int_en': 'подстрочник · глосса над WH-греческим',
};

/// Основной перевод пользователя: настройка или первый доступный
/// модуль (защита от id, которого нет на этой платформе).
String mainModuleId() {
  if (kModules.containsKey(settings.defaultModule)) {
    return settings.defaultModule;
  }
  return kModules.containsKey('russyn') ? 'russyn' : kModules.keys.first;
}

final Map<String, ModuleDoc> _cache = {};

/// id модуля -> путь к .sb (из скана каталога данных).
final Map<String, String> _sbPaths = {};

/// Путь к .sb модуля, если он найден в каталоге данных (нужен поиску).
String? modulePathOf(String id) => _sbPaths[id];

/// Каталог данных приложения (модули/userdata) — для импорта .sb.
/// На web пустая строка — файлового каталога нет.
String appDataDir() {
  try {
    return dataDir();
  } catch (_) {
    return '';
  }
}

/// Скан каталога модулей — один раз на запуск.
Future<void>? _scan;

Future<void> _scanModules() => _scan ??= () async {
  for (final m in await bridgeListModules()) {
    _sbPaths[m.id] = m.path;
    if (m.title.isNotEmpty) {
      kModules[m.id] = m.title;
    } else {
      // Модуль без названия показываем по id — заголовок
      // подставится из meta после первой загрузки.
      kModules.putIfAbsent(m.id, () => m.id);
    }
  }
}();

/// Пересканировать каталог модулей (после импорта нового .sb).
Future<void> rescanModules() async {
  _scan = null;
  _cache.clear();
  _sbPaths.clear();
  await _scanModules();
}

/// Загрузить документ модуля:
/// 1) если есть .sb — читаем его через Rust-мост (главы — лениво);
/// 2) иначе — предвыгруженный JSON-ассет прототипа.
Future<ModuleDoc> loadModule(String id) async {
  if (_cache.containsKey(id)) return _cache[id]!;
  await _scanModules();

  final path = _sbPaths[id];
  if (path != null) {
    final doc = await _loadSbModule(id, path);
    if (doc != null) return _cache[id] = doc;
  }

  final raw = await rootBundle.loadString('assets/data/$id.json');
  final doc = ModuleDoc.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  _cache[id] = doc;
  return doc;
}

/// Документ из настоящего .sb: каталог сразу, главы — по требованию
/// через chapterLoader (тот же JSON, что выдаёт export.rs).
Future<ModuleDoc?> _loadSbModule(String id, String path) async {
  final raw = await bridgeModuleDoc(path);
  if (raw == null) return null;
  final doc = ModuleDoc.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  if (doc.title.isNotEmpty) kModules[id] = doc.title;
  return ModuleDoc(
    id: doc.id.isEmpty ? id : doc.id,
    title: doc.title,
    language: doc.language,
    books: doc.books,
    chapters: doc.chapters,
    verseCounts: doc.verseCounts,
    chapterLoader: (code, n) => bridgeChapterDoc(path, code, n),
  );
}
