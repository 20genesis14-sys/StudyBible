/// Нативная реализация моста к Rust-ядру через flutter_rust_bridge.
///
/// Загружает libstudybible_flutter_bridge (собирается Dart build hook
/// `hook/build.dart` через flutter_rust_bridge_hooks → native_toolchain_rust).
/// Под `flutter test` flutter_tester не добавляет native-asset в пути
/// dlopen — тогда .so ищется вручную (`_findLib`). Каталог данных —
/// `STUDYBIBLE_DATA`
/// (по умолчанию `~/StudyBible-data`, на Windows `C:\StudyBible-data`).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import 'package:path_provider/path_provider.dart';

import 'native_bridge.dart';
import 'src/rust/frb_generated.dart';
import 'src/rust/api/module.dart' as api_module;
import 'src/rust/api/userdata.dart' as api_userdata;
import 'src/rust/api/voice.dart' as api_voice;

/// Инициализация RustLib — один раз на процесс.
Future<void>? _init;

Future<void> _ensureInit() => _init ??= _initImpl();

Future<void> _initImpl() async {
  if (Platform.isAndroid || Platform.isIOS) {
    _mobileDataDir = (await getApplicationDocumentsDirectory()).path;
  }
  await _seedBundledModules();
  try {
    await RustLib.init();
    return;
  } catch (_) {
    // flutter test не раскладывает hook-ассеты по путям dlopen —
    // ищем собранную библиотеку сами и отдаём её явно.
  }
  final lib = _findLib();
  if (lib == null) {
    // Повторный вызов — вернёт исходную ошибку загрузки.
    await RustLib.init();
    return;
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(lib.path));
}

/// Модуль, упакованный в сборку как ассет `.sbz` (решение
/// 08.10.2026: поставляем ровно один базовый перевод, остальные —
/// импортом пользователя). .sbz читается store напрямую
/// (распаковка в ОЗУ при открытии), распаковывать не нужно.
const _bundledModules = ['russyn'];

/// Скопировать встроенные .sbz в каталог данных при первом запуске:
/// пропускаем модуль, если уже есть .sb или .sbz — импортированные
/// пользователем и ранее посеянные файлы не трогаем.
Future<void> _seedBundledModules() async {
  final dir = Directory(_modulesDir());
  for (final id in _bundledModules) {
    final sbz = File('${dir.path}${Platform.pathSeparator}$id.sbz');
    final sb = File('${dir.path}${Platform.pathSeparator}$id.sb');
    if (sbz.existsSync() || sb.existsSync()) continue;
    try {
      final bytes = await rootBundle.load('assets/modules/$id.sbz');
      await dir.create(recursive: true);
      await sbz.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    } catch (e) {
      stderr.writeln('[bridge] распаковка модуля $id: $e');
    }
  }
}

/// Имя динамической библиотеки моста на текущей платформе.
String get _libName {
  if (Platform.isWindows) return 'studybible_flutter_bridge.dll';
  if (Platform.isMacOS) return 'libstudybible_flutter_bridge.dylib';
  return 'libstudybible_flutter_bridge.so';
}

/// Поиск собранной библиотеки моста в типичных местах сборки.
/// Путь относителен к корню пакета (там живёт `flutter test`).
File? _findLib() {
  final sep = Platform.pathSeparator;
  final name = _libName;
  final candidates = <String>[
    'rust${sep}target${sep}release$sep$name',
    'rust${sep}target${sep}debug$sep$name',
    // Крейт — член workspace, артефакты лежат в общем target/ корня.
    '..$sep..${sep}target${sep}debug$sep$name',
    '..$sep..${sep}target${sep}release$sep$name',
    'build${sep}native_assets${sep}linux$sep$name',
  ];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  // Самый свежий результат сборки Dart build hook (flutter test).
  final hooks = Directory('.dart_tool${sep}hooks_runner');
  if (hooks.existsSync()) {
    final hits =
        hooks
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('$sep$name'))
            .toList()
          ..sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
          );
    if (hits.isNotEmpty) return hits.first;
  }
  return null;
}

/// Каталог данных: STUDYBIBLE_DATA или ~/StudyBible-data (C:\StudyBible-data);
/// на Android/iOS — каталог документов приложения (path_provider).
String dataDir() {
  final env = Platform.environment['STUDYBIBLE_DATA'];
  if (env != null && env.isNotEmpty) return env;
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  if (Platform.isAndroid || Platform.isIOS) {
    // path_provider резолвится в _initImpl; до первого вызова моста —
    // фоллбэк на домашний путь (обычно файлы приложения).
    return _mobileDataDir ?? '$home${Platform.pathSeparator}StudyBible-data';
  }
  if (Platform.isWindows) {
    // Решение 08.10.2026: никаких абсолютных путей — данные живут
    // в пользовательском каталоге (видимое место для импорта модулей
    // и бэкапа userdata).
    return '$home${Platform.pathSeparator}Documents${Platform.pathSeparator}StudyBible-data';
  }
  return '$home${Platform.pathSeparator}StudyBible-data';
}

/// Заполненный каталог документов на мобильных (ленивая инициализация
/// до первого обращения к мосту, см. _ensureInit).
String? _mobileDataDir;

String _modulesDir() => '${dataDir()}${Platform.pathSeparator}modules';

/// Под flutter test (FLUTTER_TEST=true) пользовательская БД уходит
/// во временный каталог — тесты не трогают реальный userdata.db.
String _userdataPath() {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    final d = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}studybible-test',
    )..createSync(recursive: true);
    return '${d.path}${Platform.pathSeparator}userdata.db';
  }
  return '${dataDir()}${Platform.pathSeparator}userdata.db';
}

/// Модули .sb в каталоге данных; пусто, если каталога нет или мост упал.
Future<List<SbModuleInfo>> bridgeListModules() async {
  try {
    await _ensureInit();
    final list = await api_module.listModules(dir: _modulesDir());
    return [
      for (final m in list)
        SbModuleInfo(
          id: m.id,
          title: m.title,
          language: m.language,
          path: m.path,
        ),
    ];
  } catch (_) {
    return const [];
  }
}

/// Ошибки моста — не фатальны: лог в stderr, ответ «нет данных»,
/// и UI остаётся на фоллбэках (JSON-ассеты / прогресс в памяти).
Future<T?> _guard<T>(String what, Future<T?> Function() f) async {
  try {
    await _ensureInit();
    return await f();
  } catch (e) {
    stderr.writeln('[bridge] $what: $e');
    return null;
  }
}

/// JSON-документ модуля формата export.rs (без глав).
Future<String?> bridgeModuleDoc(String path) =>
    _guard('moduleDoc', () => api_module.moduleDoc(path: path));

/// Глава в формате export.rs; null — если её нет в модуле.
Future<String?> bridgeChapterDoc(String path, String book, int chapter) =>
    _guard(
      'chapterDoc',
      () => api_module.chapterDoc(path: path, book: book, chapter: chapter),
    );

Future<String?> bridgeProgressLoad() => _guard(
  'progressLoad',
  () => api_userdata.progressLoad(path: _userdataPath()),
);

Future<void> bridgeProgressMarkRead(String book, int chapter) => _guard(
  'progressMarkRead',
  () => api_userdata.progressMarkRead(
    path: _userdataPath(),
    book: book,
    chapter: chapter,
  ),
);

Future<void> bridgeProgressSetPosition(String book, int chapter, int verse) =>
    _guard(
      'progressSetPosition',
      () => api_userdata.progressSetPosition(
        path: _userdataPath(),
        book: book,
        chapter: chapter,
        verse: verse,
      ),
    );

Future<void> bridgeProgressSetVerse(String book, int chapter, int verse) =>
    _guard(
      'progressSetVerse',
      () => api_userdata.progressSetVerse(
        path: _userdataPath(),
        book: book,
        chapter: chapter,
        verse: verse,
      ),
    );

Future<void> bridgeProgressReset() => _guard(
  'progressReset',
  () => api_userdata.progressReset(path: _userdataPath()),
);

// ---------- записи пользователя (заметки/закладки/выделения) ----------

UserEntry _entry(api_userdata.UserEntryInfo e) => UserEntry(
  id: e.id,
  module: e.module,
  kind: e.kind,
  book: e.book,
  chapter: e.chapter.toInt(),
  verse: e.verse.toInt(),
  text: e.text,
  context: e.context,
  created: e.created.toInt(),
  updated: e.updated.toInt(),
);

/// Записи одного вида; module=null — по всем модулям.
Future<List<UserEntry>> bridgeEntriesList(String kind, {String? module}) async {
  final list = await _guard(
    'entriesList',
    () => api_userdata.entriesList(
      path: _userdataPath(),
      kind: kind,
      module: module,
    ),
  );
  return [
    for (final e in list ?? const <api_userdata.UserEntryInfo>[]) _entry(e),
  ];
}

/// Добавить запись к стиху модуля; null — ошибка моста.
Future<String?> bridgeEntryAdd({
  required String kind,
  required String module,
  required String book,
  required int chapter,
  required int verse,
  required String text,
  required String context,
}) => _guard(
  'entryAdd',
  () => api_userdata.entryAdd(
    path: _userdataPath(),
    kind: kind,
    module: module,
    book: book,
    chapter: chapter,
    verse: verse,
    text: text,
    context: context,
  ),
);

Future<bool> bridgeEntryUpdate(String id, String text) async =>
    await _guard(
      'entryUpdate',
      () => api_userdata.entryUpdate(path: _userdataPath(), id: id, text: text),
    ) ==
    true;

Future<bool> bridgeEntryRemove(String id) async =>
    await _guard(
      'entryRemove',
      () => api_userdata.entryRemove(path: _userdataPath(), id: id),
    ) ==
    true;

/// Перепривязка записей после установки/обновления модуля (вопрос №12):
/// возвращает строку-итог или null при ошибке моста.
Future<String?> bridgeEntriesRelink() async {
  await _ensureInit();
  return _guard('entriesRelink', () async {
    return api_userdata.entriesRelink(path: _userdataPath());
  });
}

// ---------- версификации (ADR 0015, вопрос 8) ----------

/// Перевод стиха между версификациями через org (ядро):
/// `fromVrs`/`toVrs` — имена `.vrs` ('rsc','eng','vul',…).
/// Ошибка моста/неизвестная версификация — тот же номер.
Future<List<({String book, int chapter, int verse})>> bridgeConvertVerse(
  String book,
  int chapter,
  int verse,
  String fromVrs,
  String toVrs,
) async {
  final pts = await _guard(
    'convertVerse',
    () => api_module.convertVerse(
      book: book,
      chapter: chapter,
      verse: verse,
      fromVrs: fromVrs,
      toVrs: toVrs,
    ),
  );
  if (pts == null) {
    return [(book: book, chapter: chapter, verse: verse)];
  }
  return [
    for (final p in pts)
      (book: p.book, chapter: p.chapter.toInt(), verse: p.verse.toInt()),
  ];
}

// ---------- словарь (entries, ADR 0016) ----------

/// Страница заголовков словаря; prefix — строчный префикс norm.
Future<List<DictEntryInfo>> bridgeDictEntries(
  String path, {
  int offset = 0,
  int limit = 200,
  String prefix = '',
}) async {
  final list = await _guard(
    'dictEntries',
    () => api_module.dictEntries(
      path: path,
      offset: offset,
      limit: limit,
      prefix: prefix,
    ),
  );
  return [
    for (final e in list ?? const <api_module.DictEntry>[])
      DictEntryInfo(ord: e.ord.toInt(), headword: e.headword),
  ];
}

/// Статья словаря по ord; null — нет такой или модуль не словарь.
Future<DictArticleInfo?> bridgeDictEntry(String path, int ord) async {
  final a = await _guard(
    'dictEntry',
    () => api_module.dictEntry(path: path, ord: ord),
  );
  return a == null
      ? null
      : DictArticleInfo(ord: a.ord.toInt(), headword: a.headword, text: a.text);
}

// ---------- поиск ----------

/// Поиск по FTS-индексу модуля; кэш-файл — `<module>.idx` рядом.
Future<List<SearchHit>> bridgeModuleSearch(
  String modulePath,
  String query, {
  int limit = 50,
}) async {
  final hits = await _guard(
    'moduleSearch',
    () => api_module.moduleSearch(
      modulePath: modulePath,
      cachePath: '$modulePath.idx',
      query: query,
      limit: limit,
    ),
  );
  return [
    for (final h in hits ?? const <api_module.SearchHitInfo>[])
      SearchHit(
        book: h.book,
        chapter: h.chapter.toInt(),
        verse: h.verse.toInt(),
        snippet: h.snippet,
      ),
  ];
}

// ---------- автоударения (RUAccent, нейробэкенд; ADR 0017) ----------

/// Загрузить модель акцентуации из ассетов (один раз на процесс —
/// мемоизируется вызывающей стороной). Ошибки моста — молча:
/// чтение идёт без ударений.
Future<void> bridgeAccentInit(
  Uint8List model,
  String vocab,
  Uint8List yoGz,
  Uint8List lexiconGz,
) => _guard(
  'accentInit',
  () => api_voice.accentInit(
    model: model,
    vocab: vocab,
    yoGz: yoGz,
    lexiconGz: lexiconGz,
  ),
);

/// Текст с ударениями U+0301 и ё по словарю; при любой ошибке —
/// исходный текст (чтение не должно падать из-за ударений).
Future<String> bridgeAccentText(String text) async =>
    await _guard('accentText', () => api_voice.accentText(text: text)) ?? text;
