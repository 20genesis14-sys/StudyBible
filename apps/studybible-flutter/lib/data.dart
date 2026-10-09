/// Каталог книг (короткие русские имена + группа) и загрузка модулей.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'models.dart';
// Мост к данным: на нативных платформах — Rust-ядро через ffi,
// на web — sqlite3.wasm читает те же .sb из web/modules/,
// фоллбэк — предвыгруженные JSON-ассеты.
import 'l10n.dart';
import 'native_bridge_stub.dart'
    if (dart.library.html) 'native_bridge_web.dart'
    if (dart.library.io) 'native_bridge_io.dart';
import 'state.dart';
import 'theme.dart';

/// Код → (короткое имя, группа). Порядок = канонический (66 книг).
const List<(String, String, BookGroup)> kCatalog = [
  ('GEN', 'Быт', BookGroup.torah),
  ('EXO', 'Исх', BookGroup.torah),
  ('LEV', 'Лев', BookGroup.torah),
  ('NUM', 'Чис', BookGroup.torah),
  ('DEU', 'Втор', BookGroup.torah),
  ('JOS', 'Нав', BookGroup.hist),
  ('JDG', 'Суд', BookGroup.hist),
  ('RUT', 'Руф', BookGroup.hist),
  ('1SA', '1Цар', BookGroup.hist),
  ('2SA', '2Цар', BookGroup.hist),
  ('1KI', '3Цар', BookGroup.hist),
  ('2KI', '4Цар', BookGroup.hist),
  ('1CH', '1Пар', BookGroup.hist),
  ('2CH', '2Пар', BookGroup.hist),
  ('EZR', 'Езд', BookGroup.hist),
  ('NEH', 'Неем', BookGroup.hist),
  ('EST', 'Есф', BookGroup.hist),
  ('JOB', 'Иов', BookGroup.poet),
  ('PSA', 'Пс', BookGroup.poet),
  ('PRO', 'Притч', BookGroup.poet),
  ('ECC', 'Еккл', BookGroup.poet),
  ('SNG', 'Песн', BookGroup.poet),
  ('ISA', 'Ис', BookGroup.majp),
  ('JER', 'Иер', BookGroup.majp),
  ('LAM', 'Плач', BookGroup.majp),
  ('EZK', 'Иез', BookGroup.majp),
  ('DAN', 'Дан', BookGroup.majp),
  ('HOS', 'Ос', BookGroup.minp),
  ('JOL', 'Иоил', BookGroup.minp),
  ('AMO', 'Ам', BookGroup.minp),
  ('OBA', 'Авд', BookGroup.minp),
  ('JON', 'Ион', BookGroup.minp),
  ('MIC', 'Мих', BookGroup.minp),
  ('NAM', 'Наум', BookGroup.minp),
  ('HAB', 'Авв', BookGroup.minp),
  ('ZEP', 'Соф', BookGroup.minp),
  ('HAG', 'Агг', BookGroup.minp),
  ('ZEC', 'Зах', BookGroup.minp),
  ('MAL', 'Мал', BookGroup.minp),
  ('MAT', 'Мф', BookGroup.gosp),
  ('MRK', 'Мк', BookGroup.gosp),
  ('LUK', 'Лк', BookGroup.gosp),
  ('JHN', 'Ин', BookGroup.gosp),
  ('ACT', 'Деян', BookGroup.acts),
  ('ROM', 'Рим', BookGroup.paul),
  ('1CO', '1Кор', BookGroup.paul),
  ('2CO', '2Кор', BookGroup.paul),
  ('GAL', 'Гал', BookGroup.paul),
  ('EPH', 'Еф', BookGroup.paul),
  ('PHP', 'Флп', BookGroup.paul),
  ('COL', 'Кол', BookGroup.paul),
  ('1TH', '1Фес', BookGroup.paul),
  ('2TH', '2Фес', BookGroup.paul),
  ('1TI', '1Тим', BookGroup.paul),
  ('2TI', '2Тим', BookGroup.paul),
  ('TIT', 'Тит', BookGroup.paul),
  ('PHM', 'Флм', BookGroup.paul),
  ('HEB', 'Евр', BookGroup.paul),
  ('JAS', 'Иак', BookGroup.cath),
  ('1PE', '1Пет', BookGroup.cath),
  ('2PE', '2Пет', BookGroup.cath),
  ('1JN', '1Ин', BookGroup.cath),
  ('2JN', '2Ин', BookGroup.cath),
  ('3JN', '3Ин', BookGroup.cath),
  ('JUD', 'Иуд', BookGroup.cath),
  ('REV', 'Откр', BookGroup.rev),
];

/// Код → короткое имя.
final Map<String, String> kShortName = {for (final e in kCatalog) e.$1: e.$2};

/// Код → короткое английское имя (для en-интерфейса).
const Map<String, String> kShortNameEn = {
  'GEN': 'Ge', 'EXO': 'Ex', 'LEV': 'Lev', 'NUM': 'Num', 'DEU': 'Deut',
  'JOS': 'Josh', 'JDG': 'Judg', 'RUT': 'Ruth', '1SA': '1Sam', '2SA': '2Sam',
  '1KI': '1Ki', '2KI': '2Ki', '1CH': '1Chr', '2CH': '2Chr', 'EZR': 'Ezra',
  'NEH': 'Neh', 'EST': 'Esth', 'JOB': 'Job', 'PSA': 'Ps', 'PRO': 'Prov',
  'ECC': 'Eccl', 'SNG': 'Song', 'ISA': 'Isa', 'JER': 'Jer', 'LAM': 'Lam',
  'EZK': 'Ezek', 'DAN': 'Dan', 'HOS': 'Hos', 'JOL': 'Joel', 'AMO': 'Amos',
  'OBA': 'Obad', 'JON': 'Jonah', 'MIC': 'Mic', 'NAM': 'Nah', 'HAB': 'Hab',
  'ZEP': 'Zeph', 'HAG': 'Hag', 'ZEC': 'Zech', 'MAL': 'Mal', 'MAT': 'Mt',
  'MRK': 'Mk', 'LUK': 'Lk', 'JHN': 'Jn', 'ACT': 'Acts', 'ROM': 'Rom',
  '1CO': '1Cor', '2CO': '2Cor', 'GAL': 'Gal', 'EPH': 'Eph', 'PHP': 'Phil',
  'COL': 'Col', '1TH': '1Thess', '2TH': '2Thess', '1TI': '1Tim',
  '2TI': '2Tim', 'TIT': 'Titus', 'PHM': 'Phlm', 'HEB': 'Heb', 'JAS': 'Jas',
  '1PE': '1Pet', '2PE': '2Pet', '1JN': '1Jn', '2JN': '2Jn', '3JN': '3Jn',
  'JUD': 'Jude', 'REV': 'Rev',
};

/// Короткое имя книги по коду, по языку интерфейса.
/// [fallback] — для книг вне каталога 66 (название из модуля).
String bookShort(String code, [String? fallback]) => isEn
    ? (kShortNameEn[code] ?? fallback ?? kShortName[code] ?? code)
    : (kShortName[code] ?? fallback ?? code);

/// Код → группа.
final Map<String, BookGroup> kBookGroup = {
  for (final e in kCatalog) e.$1: e.$3,
};

/// Разделы сетки.
String get kSectionOt =>
    tr('ВЕТХИЙ ЗАВЕТ', 'OLD TESTAMENT');
String get kSectionNt =>
    tr('НОВЫЙ ЗАВЕТ', 'NEW TESTAMENT');
// Секция книг модуля вне каталога 66 (второканонические и пр.).
String get kSectionOther =>
    tr('НЕКАНОНИЧЕСКИЕ КНИГИ', 'DEUTEROCANONICAL BOOKS');
const int kNtFirstIndex = 39; // 'MAT'

/// Индекс книги в каноне (для переходов через границы книг).
int bookIndexOf(String code) => kCatalog.indexWhere((e) => e.$1 == code);

/// Известные модули: названия для UI по id.
/// Наполняется сканом .sb-файлов каталога данных (нативные платформы);
/// JSON-ассеты остаются фоллбэком там, где .sb нет (и единственным
/// источником на web — см. native_bridge_stub.dart).
/// Личные модули сюда НЕ вписываются: они появляются
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

/// Имена модулей для en-интерфейса (id → имя; фоллбэк — kModules).
const Map<String, String> kModulesEn = {
  'russyn': 'Synodal Translation',
  'ru_rob': 'Russian Open Bible',
  'kjv2006': 'KJV 2006 (Strong’s)',
  'oshb': 'Hebrew Bible (OSHB)',
  'ugnt': 'Greek NT (UGNT)',
};

/// Имя модуля для UI по языку интерфейса; у модулей, найденных
/// сканом, — их собственный title из kModules.
String moduleName(String id) =>
    isEn ? (kModulesEn[id] ?? kModules[id] ?? id) : (kModules[id] ?? id);

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

const Map<String, String> kModuleTagsEn = {
  'englsv': 'critical text · YHWH · Strong’s',
  'engbsb': 'critical apparatus · Strong’s',
  'oshb': 'original · Hebrew · Strong’s',
  'ugnt': 'original · Greek · Strong’s',
  'eng-kjv2006': 'Strong’s numbers',
  'ru_rob': 'CC BY-SA 4.0',
  'int_en': 'interlinear · gloss over WH Greek',
};

/// Метка модуля для списка (ADR 0016): сначала жёсткая таблица
/// (знакомые модули), затем выводимая из kind/features уже
/// загруженного документа. null — метки нет.
String? moduleTag(String id) {
  final tags = isEn ? kModuleTagsEn : kModuleTags;
  if (tags.containsKey(id)) return tags[id];
  final doc = _cache[id];
  if (doc == null) return null;
  final parts = <String>[
    if (doc.kind == 'interlinear') tr('подстрочник', 'interlinear'),
    if (doc.kind == 'commentary') tr('комментарии', 'commentary'),
    if (doc.kind == 'dictionary') tr('словарь', 'dictionary'),
    if (doc.features.contains('strongs')) tr('Стронг', 'Strong’s'),
    if (doc.features.contains('variants')) tr('аппарат', 'apparatus'),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Установленные модули (id → имя): только реально найденные
/// сканом в каталоге данных (на web — манифест index.json бандла).
/// Решение 08.10.2026: списки выбора перевода показывают строго
/// установленные модули; kModules остаётся справочником имён.
Map<String, String> get installedModules => {
  for (final id in _sbPaths.keys) id: moduleName(id),
};

/// Основной перевод пользователя: настройка или первый
/// установленный модуль (защита от id, которого нет на устройстве).
String mainModuleId() {
  if (_sbPaths.containsKey(settings.defaultModule)) {
    return settings.defaultModule;
  }
  return _sbPaths.containsKey('russyn')
      ? 'russyn'
      : (_sbPaths.keys.isEmpty ? 'russyn' : _sbPaths.keys.first);
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
    kind: doc.kind,
    features: doc.features,
    versification: doc.versification,
  );
}
