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
import 'search_norm.dart' show normForIndex, normSearchQuery, normVersion;

/// Открытые (свободные по лицензии) модули, которые скрипт кладёт
/// в web/modules/. Личные модули пользователя сюда не попадают.
/// 08.10.2026: в бандле только базовый russyn (как на остальных
/// платформах); прочие модули — ручной подкладкой на хостинге
/// (файл в web/modules/ + запись в index.json; импорта из UI
/// на web нет — import_module_stub). Формат на web — .sb
/// (sqlite3.wasm читает сырой sqlite; .sbz требует zstd-пути,
/// которого в веб-мосту нет — отклонение зафиксировано в DECISIONS).
const kBundledModules = ['russyn'];

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
  // SPA-сервер отдаёт index.html с кодом 200 на любой путь, поэтому
  // решаем по магическим байтам, а не по статусу.
  Uint8List? bytes;
  final respGz = await web.window.fetch('$path.gz'.toJS).toDart;
  if (respGz.status == 200 && respGz.body != null) {
    final gz = (await respGz.arrayBuffer().toDart).toDart.asUint8List();
    if (gz.length > 1 && gz[0] == 0x1f && gz[1] == 0x8b) {
      final ds = web.DecompressionStream('gzip');
      final piped = web.Response(gz.toJS).body!.pipeThrough(
        web.ReadableWritablePair(readable: ds.readable, writable: ds.writable),
      );
      bytes = (await web.Response(
        piped,
      ).arrayBuffer().toDart).toDart.asUint8List();
    }
  }
  if (bytes == null) {
    final resp = await web.window.fetch(path.toJS).toDart;
    // Без проверки статуса в sqlite уезжает тело 404-страницы
    // («file is not a database» дальше по стеку, молчаливая «…»
    // в UI сравнения). Модуль из index.json, которого нет в бандле,
    // должен падать здесь с понятной причиной.
    if (resp.status != 200) {
      throw StateError('module not found: $path (HTTP ${resp.status})');
    }
    bytes = (await resp.arrayBuffer().toDart).toDart.asUint8List();
  }
  // VFS нормализует имя файла к абсолютному виду ('/modules/...'),
  // поэтому кладём буфер под обоими ключами.
  final buf = Uint8Buffer()..addAll(bytes);
  _fs!.fileData[path] = buf;
  _fs!.fileData['/$path'] = buf;

  // vfs указан явно: wasm-сборка не ставит файловую систему
  // по умолчанию сама, даже при makeDefault. Открываем на запись:
  // база — наша копия в памяти, а мост достраивает в ней таблицу
  // `fts` в фоне, если в модуле её нет (решение 12.10.2026: веб
  // индексирует сам, модуль не раздуваем).
  final db = _sqlite!.open(path, mode: OpenMode.readWrite, vfs: _fs!.name);
  _dbs[path] = db;
  _ftsJobs[path] ??= _buildFtsInMemory(db);
  return db;
}

/// Фоновая индексация модуля: по одной Future на файл. Модуль открыт
/// и читаем сразу; пока индекс не готов, поиск идёт LIKE-сканом —
/// таблица `fts` без `meta.norm_version` поиск не трогает.
final Map<String, Future<void>> _ftsJobs = {};

/// Достраивает FTS5-индекс в открытой (in-memory) базе модуля.
/// `meta.norm_version` выставляется только после полной вставки —
/// поиск по полупостроенной таблице исключён. Батчи разделены
/// микрозадачами, чтобы не замораживать единственный изолят.
Future<void> _buildFtsInMemory(CommonDatabase db) async {
  try {
    final has = db.select(
      "SELECT count(*) AS n FROM sqlite_master WHERE name='fts' AND sql LIKE '%VIRTUAL TABLE%'",
    );
    if ((has.first['n'] as num) > 0) return;
    final hasVerses = db.select(
      "SELECT count(*) AS n FROM sqlite_master WHERE name='verses' AND type='table'",
    );
    if ((hasVerses.first['n'] as num) == 0) return; // словари и пр.
    db.execute(
      "CREATE VIRTUAL TABLE fts USING fts5("
      'book UNINDEXED, chapter UNINDEXED, verse UNINDEXED, norm, '
      "tokenize='unicode61')",
    );
    final rows = db.select(
      'SELECT b.code AS c, v.chapter AS ch, v.verse AS v, v.text AS t '
      'FROM verses v JOIN books b ON b.book_id = v.book_id',
    );
    const batch = 500;
    for (var i = 0; i < rows.length; i += batch) {
      db.execute('BEGIN');
      try {
        final ins = db.prepare('INSERT INTO fts VALUES(?1, ?2, ?3, ?4)');
        for (final r in rows.skip(i).take(batch)) {
          ins.execute([
            '${r['c']}',
            r['ch'],
            r['v'],
            normForIndex('${r['t']}'),
          ]);
        }
        ins.close();
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
      // Отдаём управление циклу событий — UI остаётся отзывчивым.
      await Future<void>.delayed(Duration.zero);
    }
    db.execute(
      "INSERT OR REPLACE INTO meta(key, value) VALUES('norm_version', ?)",
      [normVersion],
    );
  } catch (_) {
    // Модуль без стихов/битая схема — остаётся LIKE-скан.
  }
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
        'SELECT b.code, MAX(v.chapter) AS c FROM verses v '
        'JOIN books b ON b.book_id=v.book_id GROUP BY v.book_id',
      ))
        r['code'] as String: (r['c'] as num).toInt(),
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
        'SELECT b.code, v.chapter, MAX(v.verse) AS v FROM verses v '
        'JOIN books b ON b.book_id=v.book_id '
        'GROUP BY v.book_id, v.chapter',
      ))
        '${r['code']}:${r['chapter']}': (r['v'] as num).toInt(),
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
      return {
        'n': r['kind'],
        'c': r['caller'],
        't': r['text'],
        'a': r['attrs'], // привязка к части стиха (ADR 0016)
      };
  }
}

/// UTF-8 срез строки по байтовым смещениям (spans.start/len — в байтах).
String _byteSlice(String s, int start, int len) =>
    utf8.decode(utf8.encode(s).sublist(start, start + len));

/// Глава в формате export.rs `{"n":..,"blocks":[..]}`; null, если её нет —
/// зеркало api/module.rs::chapter_doc и store::Module::chapter.
///
/// Схема 1.1: книги адресуются book_id, текст стиховых спанов — срез
/// `verses.text` по (verse,start,len); маркеры 'v' хранятся только у
/// пустых стихов, для остальных граница синтезируется по смене verse —
/// как в store::Module::chapter.
Future<String?> bridgeChapterDoc(String path, String book, int chapter) async {
  try {
    final db = await _openDb(path);
    final br = db.select('SELECT book_id FROM books WHERE code=?', [book]);
    if (br.isEmpty) return null;
    final bid = br.first['book_id'];
    // Сырой текст стихов для нарезки спанов.
    final vtexts = <int, String>{
      for (final r in db.select(
        'SELECT verse, text FROM verses WHERE book_id=? AND chapter=?',
        [bid, chapter],
      ))
        (r['verse'] as num).toInt(): '${r['text']}',
    };
    final blocks = db.select(
      'SELECT seq, marker FROM blocks WHERE book_id=? AND chapter=? ORDER BY seq',
      [bid, chapter],
    );
    if (blocks.isEmpty) return null;

    final st = db.prepare(
      'SELECT kind, num, verse, start, len, style, attrs, caller, text '
      'FROM spans WHERE book_id=? AND chapter=? AND block=? ORDER BY seq',
    );
    final out = <Map<String, dynamic>>[];
    int? cur;
    for (final b in blocks) {
      final marker = b['marker'] as String;
      final spans = <Map<String, dynamic>>[];
      for (final r in st.select([bid, chapter, b['seq']])) {
        final v = (r['verse'] as num?)?.toInt();
        // Маркер границы: спан принадлежит новому ненулевому стиху.
        if (v != null && v != 0 && cur != v) {
          spans.add({'v': v});
          cur = v;
        } else if (v != null) {
          cur = v;
        }
        if (r['kind'] == 't' && v != null && r['start'] != null) {
          // Текст — срез из канонического verses.text.
          final raw = vtexts[v] ?? '';
          spans.add({
            't': _byteSlice(
              raw,
              (r['start'] as num).toInt(),
              (r['len'] as num).toInt(),
            ),
            's': r['style'],
            'a': r['attrs'],
          });
        } else {
          spans.add(_spanJson(r));
        }
      }
      out.add({'k': _blockKind(marker), 'm': marker, 's': spans});
    }
    st.close();

    // ADR 0016: аппарат главы, если таблица есть (у старых .sb — нет).
    var variants = <Map<String, dynamic>>[];
    try {
      final vs = db.select(
        'SELECT id, verse, token_from, token_to FROM variants '
        'WHERE book_id=? AND chapter=? ORDER BY verse, token_from',
        [bid, chapter],
      );
      for (final v in vs) {
        final readings = [
          for (final r in db.select(
            'SELECT id, text, is_base FROM readings '
            'WHERE variant_id=? ORDER BY seq',
            [v['id']],
          ))
            {
              't': r['text'],
              'base': (r['is_base'] as num) != 0,
              'w': [
                for (final s in db.select(
                  'SELECT siglum FROM witnesses WHERE reading_id=? '
                  'ORDER BY siglum',
                  [r['id']],
                ))
                  s['siglum'],
              ],
            },
        ];
        variants.add({
          'verse': v['verse'],
          'from': v['token_from'],
          'to': v['token_to'],
          'readings': readings,
        });
      }
    } catch (_) {
      // Нет таблиц аппарата — модуль без variants.
    }

    return jsonEncode({'n': chapter, 'blocks': out, 'variants': variants});
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

/// Перепривязка записей к модулям — на web пока нет (вопрос №12).
Future<String?> bridgeEntriesRelink() async => null;

// ---------- словарь (entries, ADR 0016) ----------

/// Страница заголовков словаря; prefix — строчный префикс norm.
Future<List<DictEntryInfo>> bridgeDictEntries(
  String path, {
  int offset = 0,
  int limit = 200,
  String prefix = '',
}) async {
  try {
    final db = await _openDb(path);
    final rows = db.select(
      "SELECT ord, headword FROM entries WHERE norm LIKE ? || '%' "
      'ORDER BY ord LIMIT ? OFFSET ?',
      [prefix.toLowerCase(), limit, offset],
    );
    return [
      for (final r in rows)
        DictEntryInfo(
          ord: (r['ord'] as num).toInt(),
          headword: '${r['headword']}',
        ),
    ];
  } catch (_) {
    return const []; // таблицы entries нет — модуль не словарь
  }
}

/// Статья словаря по ord; null — нет такой.
Future<DictArticleInfo?> bridgeDictEntry(String path, int ord) async {
  try {
    final db = await _openDb(path);
    final rows = db.select('SELECT headword, text FROM entries WHERE ord=?', [
      ord,
    ]);
    if (rows.isEmpty) return null;
    return DictArticleInfo(
      ord: ord,
      headword: '${rows.first['headword']}',
      text: '${rows.first['text']}',
    );
  } catch (_) {
    return null;
  }
}

// ---------- поиск ----------

// Нормализация запроса и её версия — lib/search_norm.dart
// (вынесена для юнит-тестов; правила — лёгкий аналог
// `core::normalize::for_search`, см. там).

/// Поиск по модулю: есть встроенная FTS5-таблица `fts` (ADR 0016) —
/// MATCH-запрос прямо по ней; иначе — LIKE-скан по спанам.
Future<List<SearchHit>> bridgeModuleSearch(
  String modulePath,
  String query, {
  int limit = 50,
}) async {
  try {
    final db = await _openDb(modulePath);
    final q = query.trim();
    if (q.isEmpty) return const [];
    final hasFts = db.select(
      "SELECT count(*) AS n FROM sqlite_master WHERE name='fts' AND sql LIKE '%VIRTUAL TABLE%'",
    );
    // Встроенный индекс годится только при совпадающей версии
    // нормализации (meta.norm_version); старый — LIKE-скан.
    final normVer = (hasFts.first['n'] as num) > 0
        ? db.select("SELECT value AS v FROM meta WHERE key='norm_version'")
        : const [];
    final ftsOk =
        (hasFts.first['n'] as num) > 0 &&
        normVer.isNotEmpty &&
        '${normVer.first['v']}' == normVersion;
    if (ftsOk) {
      final terms = normSearchQuery(q)
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .map((w) => '"${w.replaceAll('"', '""')}"')
          .toList();
      if (terms.isEmpty) return const [];
      try {
        final rows = db.select(
          "SELECT book, chapter, verse, snippet(fts, 3, '[', ']', '…', 8) AS s"
          ' FROM fts WHERE fts MATCH ? ORDER BY rank LIMIT ?',
          [terms.join(' AND '), limit],
        );
        return [
          for (final r in rows)
            SearchHit(
              book: '${r['book']}',
              chapter: (r['chapter'] as num).toInt(),
              verse: (r['verse'] as num).toInt(),
              snippet: '${r['s']}',
            ),
        ];
      } catch (_) {
        // wasm-сборка sqlite без FTS5 или битый индекс — скан ниже.
      }
    }
    // Схема 1.1: канонический текст стиха — в verses.text; код книги —
    // по books.
    final rows = db.select(
      'SELECT b.code, v.chapter, v.verse, v.text AS t FROM verses v '
      'JOIN books b ON b.book_id=v.book_id '
      "WHERE v.text LIKE ? ESCAPE '\\' "
      'ORDER BY b.ord, v.chapter, v.verse LIMIT ?',
      [
        '%${q.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%',
        limit,
      ],
    );
    return [
      for (final r in rows)
        SearchHit(
          book: '${r['code']}',
          chapter: (r['chapter'] as num).toInt(),
          verse: (r['verse'] as num?)?.toInt() ?? 0,
          snippet: '${r['t']}',
        ),
    ];
  } catch (e) {
    debugPrint('[bridge] search $modulePath: $e');
    return const [];
  }
}
