/// Реализация моста для web: читаем настоящие .sb-модули в браузере
/// через официальный sqlite3.wasm (package:sqlite3/wasm.dart) и
/// in-memory VFS — та же БД, что на десктопе через Rust-мост.
///
/// Файлы модулей не входят в репозиторий (правило «тексты — вне git»):
/// их кладут в `web/modules/` (gitignored) скриптом
/// `scripts/fetch-web-modules.ps1`, а во время работы приложение
/// скачивает их как статику и открывает read-only.
///
/// Прогресс хранится в localStorage вместо userdata.db.
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart' show debugPrint;

import 'dart:typed_data';

import 'package:sqlite3/wasm.dart';
import 'package:typed_data/typed_buffers.dart';
import 'package:web/web.dart' as web;

import 'native_bridge.dart';

/// Открытые (свободные по лицензии) модули, которые скрипт кладёт
/// в web/modules/. Личные модули пользователя сюда не попадают.
const kBundledModules = [
  'russyn',
  'ru_rob',
  'engwebp',
  'eng-kjv2006',
  'englsv',
  'engbsb',
  'oshb',
  'ugnt',
];

/// Каталог данных — в браузере файловой системы нет.
String dataDir() => '';

WasmSqlite3? _sqlite;
InMemoryFileSystem? _fs;
final Map<String, CommonDatabase> _dbs = {};

/// Инициализация wasm-ядра — одна Future на все вызовы, иначе
/// параллельные запросы создают два экземпляра sqlite и VFS
/// регистрируется не в том (sqlite: «no such vfs»).
Future<void>? _wasmInit;

Future<void> _ensureWasm() => _wasmInit ??= () async {
  _sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  final fs = InMemoryFileSystem();
  _sqlite!.registerVirtualFileSystem(fs, makeDefault: true);
  _fs = fs;
}();

Future<CommonDatabase> _openDb(String path) async {
  final cached = _dbs[path];
  if (cached != null) return cached;

  await _ensureWasm();

  // На хостинге модули лежат сжатыми (modules/*.sb.gz): передача всего
  // сайта иначе упирается в лимит деплоя. Сначала пробуем .gz и
  // распаковываем браузерным DecompressionStream; без него — сырой .sb.
  Uint8List bytes;
  final respGz = await web.window.fetch('$path.gz'.toJS).toDart;
  if (respGz.status == 200 && respGz.body != null) {
    final ds = web.DecompressionStream('gzip');
    final piped = respGz.body!.pipeThrough(
      web.ReadableWritablePair(readable: ds.readable, writable: ds.writable),
    );
    bytes = (await web.Response(
      piped,
    ).arrayBuffer().toDart).toDart.asUint8List();
  } else {
    final resp = await web.window.fetch(path.toJS).toDart;
    bytes = (await resp.arrayBuffer().toDart).toDart.asUint8List();
  }
  // VFS нормализует имя файла к абсолютному виду ('/modules/...'),
  // поэтому кладём буфер под обоими ключами.
  final buf = Uint8Buffer()..addAll(bytes);
  _fs!.fileData[path] = buf;
  _fs!.fileData['/$path'] = buf;

  // vfs указан явно: wasm-сборка не ставит файловую систему
  // по умолчанию сама, даже при makeDefault.
  final db = _sqlite!.open(path, mode: OpenMode.readOnly, vfs: _fs!.name);
  _dbs[path] = db;
  return db;
}

// ---------- каталог ----------

/// Список .sb, доступных на web: index.json рядом с файлами, если есть,
/// иначе — встроенный перечень открытых модулей.
Future<List<SbModuleInfo>> bridgeListModules() async {
  List<String> ids = kBundledModules;
  try {
    final resp = await web.window.fetch('modules/index.json'.toJS).toDart;
    if (resp.status == 200) {
      final j = jsonDecode((await resp.text().toDart).toDart);
      if (j is List) {
        return [
          for (final e in j)
            if (e is String)
              SbModuleInfo(
                id: e,
                title: '',
                language: '',
                path: 'modules/$e.sb',
              )
            else if (e is Map && e['id'] is String)
              SbModuleInfo(
                id: e['id'] as String,
                title: (e['title'] as String?) ?? '',
                language: (e['language'] as String?) ?? '',
                path: 'modules/${e['id']}.sb',
              ),
        ];
      }
    }
  } catch (_) {
    // index.json необязателен.
  }
  return [
    for (final id in ids)
      SbModuleInfo(id: id, title: '', language: '', path: 'modules/$id.sb'),
  ];
}

// ---------- модуль ----------

Map<String, String> _meta(CommonDatabase db) => {
  for (final r in db.select('SELECT key, value FROM meta'))
    r['key'] as String: r['value'] as String,
};

/// JSON-документ модуля формата export.rs (без глав) — зеркало
/// api/module.rs::module_doc.
Future<String?> bridgeModuleDoc(String path) async {
  try {
    final db = await _openDb(path);
    final meta = _meta(db);

    final chapterCounts = <String, int>{
      for (final r in db.select(
        'SELECT book, MAX(chapter) AS c FROM verses GROUP BY book',
      ))
        r['book'] as String: (r['c'] as num).toInt(),
    };

    final books = [
      for (final r in db.select('SELECT code, title FROM books ORDER BY ord'))
        {
          'code': r['code'],
          'title': r['title'],
          'chapters': chapterCounts[r['code']] ?? 0,
        },
    ];

    final verseCounts = <String, int>{
      for (final r in db.select(
        'SELECT book, chapter, MAX(verse) AS v FROM verses GROUP BY book, chapter',
      ))
        '${r['book']}:${r['chapter']}': (r['v'] as num).toInt(),
    };

    // ADR 0016: тип и возможности модуля (у старых .sb ключей нет).
    List<String> list(String? v) =>
        v == null || v.isEmpty ? const [] : v.split(',');

    return jsonEncode({
      'id': meta['id'] ?? '',
      'title': meta['title'] ?? '',
      'language': meta['language'] ?? '',
      'versification': meta['versification'] ?? '',
      'kind': meta['kind'] ?? '',
      'features': list(meta['features']),
      'rights': list(meta['rights']),
      'books': books,
      'verse_counts': verseCounts,
      'chapters': <String, dynamic>{},
    });
  } catch (e) {
    debugPrint('[bridge] module_doc $path: $e');
    return null;
  }
}

/// Тип блока по маркеру — зеркало studybible_core::text::Block::kind().
String _blockKind(String marker) {
  final base = marker.replaceAll(RegExp(r'\d+$'), '');
  const poetry = {'q', 'qr', 'qc', 'qm', 'qd'};
  const heading = {
    's',
    'ms',
    'mr',
    'r',
    'sr',
    'sp',
    'cl',
    'qa',
    'sd',
    'is',
    'iis',
    'imt',
    'imte',
    'mt',
    'mte',
    'ih',
  };
  if (poetry.contains(base)) return 'q';
  if (heading.contains(base)) return 'h';
  if (base == 'd') return 'd';
  if (base == 'b') return 'b';
  return 'p';
}

Map<String, dynamic> _spanJson(Map<String, Object?> r) {
  switch (r['kind'] as String) {
    case 'v':
      return {'v': r['num'] ?? 0};
    case 't':
      return {'t': r['text'], 's': r['style'], 'a': r['attrs']};
    default: // 'f' | 'x'
      return {'n': r['kind'], 'c': r['caller'], 't': r['text']};
  }
}

/// Глава в формате export.rs `{"n":..,"blocks":[..]}`; null, если её нет —
/// зеркало api/module.rs::chapter_doc и store::Module::chapter.
Future<String?> bridgeChapterDoc(String path, String book, int chapter) async {
  try {
    final db = await _openDb(path);
    final blocks = db.select(
      'SELECT seq, marker FROM blocks WHERE book=? AND chapter=? ORDER BY seq',
      [book, chapter],
    );
    if (blocks.isEmpty) return null;

    final st = db.prepare(
      'SELECT kind, num, style, attrs, caller, text FROM spans '
      'WHERE book=? AND chapter=? AND block=? ORDER BY seq',
    );
    final out = <Map<String, dynamic>>[];
    for (final b in blocks) {
      final marker = b['marker'] as String;
      final spans = st
          .select([book, chapter, b['seq']])
          .map(_spanJson)
          .toList();
      out.add({'k': _blockKind(marker), 'm': marker, 's': spans});
    }
    st.close();

    return jsonEncode({'n': chapter, 'blocks': out});
  } catch (e) {
    debugPrint('[bridge] chapter_doc $path $book:$chapter: $e');
    return null;
  }
}

// ---------- прогресс (localStorage вместо userdata.db) ----------

const _kRead = 'sb.read';
const _kLastVerse = 'sb.lastVerse';
const _kPosition = 'sb.position';

final _storage = web.window.localStorage;

List<String> _readList() =>
    (jsonDecode(_storage.getItem(_kRead) ?? '[]') as List)
        .whereType<String>()
        .toList();

Map<String, int> _lastVerseMap() =>
    (jsonDecode(_storage.getItem(_kLastVerse) ?? '{}') as Map).map(
      (k, v) => MapEntry('$k', (v as num).toInt()),
    );

Future<String?> bridgeProgressLoad() async => jsonEncode({
  'read': _readList(),
  'last_position': _storage.getItem(_kPosition),
  'last_verse': _lastVerseMap(),
});

Future<void> bridgeProgressMarkRead(String book, int chapter) async {
  final read = _readList();
  final key = '$book:$chapter';
  if (!read.contains(key)) {
    read.add(key);
    _storage.setItem(_kRead, jsonEncode(read));
  }
}

Future<void> bridgeProgressSetPosition(
  String book,
  int chapter,
  int verse,
) async {
  _storage.setItem(_kPosition, '$book:$chapter');
  await bridgeProgressSetVerse(book, chapter, verse);
}

Future<void> bridgeProgressSetVerse(String book, int chapter, int verse) async {
  final m = _lastVerseMap();
  m['$book:$chapter'] = verse;
  _storage.setItem(_kLastVerse, jsonEncode(m));
}

Future<void> bridgeProgressReset() async {
  _storage
    ..removeItem(_kRead)
    ..removeItem(_kLastVerse)
    ..removeItem(_kPosition);
}

// ---------- записи пользователя (localStorage вместо userdata.db) ----------

const _kEntries = 'sb.entries';

List<Map<String, dynamic>> _entries() =>
    (jsonDecode(_storage.getItem(_kEntries) ?? '[]') as List)
        .whereType<Map<String, dynamic>>()
        .toList();

void _saveEntries(List<Map<String, dynamic>> list) =>
    _storage.setItem(_kEntries, jsonEncode(list));

UserEntry _toEntry(Map<String, dynamic> m) => UserEntry(
  id: '${m['id']}',
  module: '${m['module']}',
  kind: '${m['kind']}',
  book: '${m['book']}',
  chapter: (m['chapter'] as num).toInt(),
  verse: (m['verse'] as num).toInt(),
  text: '${m['text'] ?? ''}',
  context: '${m['context'] ?? ''}',
  created: (m['created'] as num?)?.toInt() ?? 0,
  updated: (m['updated'] as num?)?.toInt() ?? 0,
);

/// Записи одного вида; module=null — по всем модулям.
Future<List<UserEntry>> bridgeEntriesList(
  String kind, {
  String? module,
}) async => [
  for (final m in _entries())
    if (m['kind'] == kind && (module == null || m['module'] == module))
      _toEntry(m),
];

/// Добавить запись; id — метка времени + размер списка (достаточно для web).
Future<String?> bridgeEntryAdd({
  required String kind,
  required String module,
  required String book,
  required int chapter,
  required int verse,
  required String text,
  required String context,
}) async {
  final list = _entries();
  final now = DateTime.now().millisecondsSinceEpoch;
  final id = 'w$now-${list.length}';
  list.add({
    'id': id,
    'module': module,
    'kind': kind,
    'book': book,
    'chapter': chapter,
    'verse': verse,
    'text': text,
    'context': context,
    'created': now,
    'updated': now,
  });
  _saveEntries(list);
  return id;
}

Future<bool> bridgeEntryUpdate(String id, String text) async {
  final list = _entries();
  for (final m in list) {
    if (m['id'] == id) {
      m['text'] = text;
      m['updated'] = DateTime.now().millisecondsSinceEpoch;
      _saveEntries(list);
      return true;
    }
  }
  return false;
}

Future<bool> bridgeEntryRemove(String id) async {
  final list = _entries();
  final before = list.length;
  list.removeWhere((m) => m['id'] == id);
  if (list.length == before) return false;
  _saveEntries(list);
  return true;
}

// ---------- поиск ----------

/// Простой поиск подстроки по тексту стихов модуля (web-фоллбэк
/// вместо FTS5 — индекс под web не строим). Сниппет без подсветки.
Future<List<SearchHit>> bridgeModuleSearch(
  String modulePath,
  String query, {
  int limit = 50,
}) async {
  try {
    final db = await _openDb(modulePath);
    final q = query.trim();
    if (q.isEmpty) return const [];
    // Текст стиха живёт в спанах kind='t'; номера стихов — в спанах
    // kind='v' (колонки verse у spans нет): выводим его оконной функцией
    // как последний 'v' перед 't' внутри главы.
    final rows = db.select(
      "SELECT book, chapter, vnum, GROUP_CONCAT(text, '') AS t FROM ("
      '  SELECT book, chapter, kind, text,'
      "    MAX(CASE WHEN kind='v' THEN num END) OVER ("
      '      PARTITION BY book, chapter ORDER BY block, seq'
      '      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS vnum'
      "    FROM spans WHERE kind IN ('v','t')) "
      "WHERE kind='t' GROUP BY book, chapter, vnum "
      "HAVING t LIKE ? ESCAPE '\\' "
      'ORDER BY book, chapter, vnum LIMIT ?',
      [
        '%${q.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%',
        limit,
      ],
    );
    return [
      for (final r in rows)
        SearchHit(
          book: '${r['book']}',
          chapter: (r['chapter'] as num).toInt(),
          verse: (r['vnum'] as num?)?.toInt() ?? 0,
          snippet: '${r['t']}',
        ),
    ];
  } catch (e) {
    debugPrint('[bridge] search $modulePath: $e');
    return const [];
  }
}
