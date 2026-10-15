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

import 'frag.dart';
import 'models.dart';
import 'native_bridge.dart';
import 'search_norm.dart'
    show ftsQuery, normForIndex, normVersion, parseSearchQuery, scanMatch;

/// Открытые (свободные по лицензии) модули, которые скрипт кладёт
/// в web/modules/. Личные модули пользователя сюда не попадают.
/// 08.10.2026: в бандле только базовый russyn; 10.10.2026 — +
/// eng-kjv2006 (KJV со Стронгом, public domain), как на остальных
/// платформах; прочие модули — ручной подкладкой на хостинге
/// (файл в web/modules/ + запись в index.json; импорта из UI
/// на web нет — import_module_stub). Формат на web — `.sbz`, как на
/// нативных платформах: zstd-кадр распаковывает вендорный
/// wasm-декодер (`web/zstd/`, шим `window.sbZstdDecompress`); при его
/// отсутствии/ошибке — фоллбэк на `.sb.gz`/`.sb` (DECISIONS).
const kBundledModules = ['russyn', 'eng-kjv2006'];

/// Каталог данных — в браузере файловой системы нет.
String dataDir() => '';

WasmSqlite3? _sqlite;
InMemoryFileSystem? _fs;
final Map<String, CommonDatabase> _dbs = {};

/// Инициализация wasm-ядра — одна Future на все вызовы, иначе
/// параллельные запросы создают два экземпляра sqlite и VFS
/// регистрируется не в том (sqlite: «no such vfs»).
Future<void>? _wasmInit;

/// Глобал из `web/zstd/sbz.js`: zstd-кадр → распакованные байты.
/// Отсутствует, если wasm-декодер не загрузился — тогда фоллбэк.
@JS('sbZstdDecompress')
external JSAny? get _sbZstdDecompress;

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

  // На хостинге модули лежат как `modules/*.sbz` — тот же контейнер,
  // что на нативных платформах; zstd-кадр распаковывает wasm-декодер
  // из web/zstd/ (шим в index.html). Дальше — старые фоллбэки:
  // `<path>.gz` через браузерный DecompressionStream и сырой .sb.
  // SPA-сервер отдаёт index.html с кодом 200 на любой путь, поэтому
  // решаем по магическим байтам, а не по статусу.
  Uint8List? bytes;
  try {
    final respZ = await web.window.fetch('${path}z'.toJS).toDart;
    if (respZ.status == 200) {
      final sbz = (await respZ.arrayBuffer().toDart).toDart.asUint8List();
      // Заголовок SBZ1 + байт кодека (0 = zstd), дальше — кадр zstd.
      if (sbz.length > 5 &&
          sbz[0] == 0x53 &&
          sbz[1] == 0x42 &&
          sbz[2] == 0x5a &&
          sbz[3] == 0x31 &&
          sbz[4] == 0) {
        final fn = _sbZstdDecompress;
        if (fn != null && fn.isA<JSFunction>()) {
          final out = (fn as JSFunction).callAsFunction(
            null,
            Uint8List.fromList(sbz.sublist(5)).toJS,
          );
          if (out.isA<JSPromise>()) {
            bytes = ((await (out as JSPromise).toDart) as JSUint8Array).toDart;
          }
        }
      }
    }
  } catch (_) {
    // Декодер не загрузился или кадр битый — уходим на .gz/.sb.
    bytes = null;
  }
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

/// Загрузить документ модуля (на web — поверх `bridgeModuleDoc`).
Future<ModuleDoc?> bridgeLoadModuleDoc(String id, String path) async {
  final raw = await bridgeModuleDoc(path);
  if (raw == null) return null;
  final doc = ModuleDoc.fromJson(jsonDecode(raw) as Map<String, dynamic>);
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
    rights: doc.rights,
    versification: doc.versification,
  );
}

Future<ChapterDoc?> bridgeLoadChapterDoc(
  String path,
  String book,
  int chapter,
) async {
  final raw = await bridgeChapterDoc(path, book, chapter);
  if (raw == null) return null;
  return ChapterDoc.fromJson(jsonDecode(raw) as Map<String, dynamic>);
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

// ---------- блоб-упаковка (ADR 0022) ----------
// Зеркало crates/studybible-store/src/pack.rs: LEB128-varint'ы,
// пул строк, записи. На web читаем только span_pack (t-спаны блока).

class _PackReader {
  _PackReader(this.buf);
  final Uint8List buf;
  int pos = 0;

  int varint() {
    var v = 0;
    var shift = 0;
    for (;;) {
      final b = buf[pos++];
      v |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return v;
      shift += 7;
    }
  }

  List<String> pool() {
    final n = varint();
    final out = <String>[];
    for (var i = 0; i < n; i++) {
      final len = varint();
      out.add(utf8.decode(buf.sublist(pos, pos + len)));
      pos += len;
    }
    return out;
  }
}

/// Одна t-запись span_pack: seq, verse?, (start,len)?, style, attrs, text.
class _PackedSpan {
  int seq = 0;
  int? verse;
  int? start;
  int? len;
  String style = '';
  String attrs = '';
  String text = '';
}

List<_PackedSpan> _decodeSpans(Uint8List blob) {
  final r = _PackReader(blob);
  final pool = r.pool();
  final n = r.varint();
  final out = <_PackedSpan>[];
  for (var i = 0; i < n; i++) {
    final flags = r.buf[r.pos++];
    final e = _PackedSpan()..seq = r.varint();
    if (flags & 1 != 0) e.verse = r.varint();
    if (flags & 2 != 0) {
      e.start = r.varint();
      e.len = r.varint();
    }
    e.style = pool[r.varint()];
    e.attrs = pool[r.varint()];
    if (flags & 4 != 0) e.text = pool[r.varint()];
    out.add(e);
  }
  return out;
}

// ---------- общий слой параллельных (ADR 0023) ----------

/// Настройка `settings.externalXrefs`: модули без своих `x`-спанов
/// получают ссылки `modules/openbible-xrefs.sb`.
bool _xrefLayerOn = true;

/// Включить/выключить общий слой параллельных мест.
Future<void> bridgeSetXrefLayer(bool enabled) async {
  _xrefLayerOn = enabled;
}

/// Координаты слоя — eng; на web конверсии версификаций нет (в io —
/// через Versification::convert), поэтому номера стихов применяются
/// как есть: главы стабильны, расхождения — только редкие псалмы.
void _injectLayerXrefs(
  List<Map<String, dynamic>> out,
  CommonDatabase db,
  String book,
  int chapter,
) {
  try {
    final layer = _dbs['modules/openbible-xrefs.sb'];
    if (layer == null) return;
    final br = layer.select('SELECT book_id FROM books WHERE code=?', [book]);
    if (br.isEmpty) return;
    final lbid = br.first['book_id'];
    final rows = layer.select(
      "SELECT verse, text FROM spans WHERE book_id=? AND chapter=? "
      "AND kind='x' AND verse IS NOT NULL ORDER BY seq",
      [lbid, chapter],
    );
    for (final r in rows) {
      _injectLayerNote(out, (r['verse'] as num).toInt(), r['text'] as String);
    }
  } catch (_) {
    // Слоя нет или он битый — чтение идёт без параллельных.
  }
}

/// Слой подмешиваем только в модули без собственных `x`-спанов.
bool _moduleHasXrefs(CommonDatabase db) {
  try {
    final r = db.select(
      "SELECT EXISTS(SELECT 1 FROM spans WHERE kind='x') AS n",
    );
    return (r.first['n'] as num) == 1;
  } catch (_) {
    return true; // сомневаемся — не дублируем
  }
}

/// x-спан слоя в конец стиха `v` потока чтения (перед маркером
/// следующего стиха или в конец блока) — как inject_verse_note
/// в api/module.rs.
void _injectLayerNote(List<Map<String, dynamic>> blocks, int v, String text) {
  for (final b in blocks) {
    final spans = b['s'] as List;
    var seen = false;
    int? at;
    for (var i = 0; i < spans.length; i++) {
      final s = spans[i];
      if (s is Map && s['v'] is num) {
        if (seen && s['v'] != v) {
          at = i;
          break;
        }
        if (s['v'] == v) seen = true;
      }
    }
    if (seen) {
      spans.insert(at ?? spans.length, {
        'n': 'x',
        'c': '+',
        't': text,
        'a': 'src="layer"',
      });
      return;
    }
  }
}

/// Открыть слой параллельных, если файл есть в бандле (не обязателен).
Future<void> _openXrefLayer() async {
  try {
    await _openDb('modules/openbible-xrefs.sb');
  } catch (_) {
    // Без слоя читаем как раньше.
  }
}

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
      'SELECT seq, kind, num, verse, start, len, style, attrs, caller, text '
      'FROM spans WHERE book_id=? AND chapter=? AND block=? ORDER BY seq',
    );
    // ADR 0022: у упакованных модулей t-спаны лежат в span_pack —
    // сливаем строки и блоб по seq.
    var hasPack = false;
    try {
      hasPack =
          (db
                      .select(
                        "SELECT count(*) AS n FROM sqlite_master "
                        "WHERE name='span_pack' AND type='table'",
                      )
                      .first['n']
                  as num) >
              0 &&
          (db.select('SELECT count(*) AS n FROM span_pack').first['n'] as num) >
              0;
    } catch (_) {}
    final out = <Map<String, dynamic>>[];
    int? cur;
    for (final b in blocks) {
      final marker = b['marker'] as String;
      final spans = <Map<String, dynamic>>[];
      // Элементы потока блока: построчные спаны + t из блоба.
      final items = <Map<String, Object?>>[
        for (final r in st.select([bid, chapter, b['seq']])) r,
      ];
      if (hasPack) {
        final pr = db.select(
          'SELECT blob FROM span_pack WHERE book_id=? AND chapter=? AND block=?',
          [bid, chapter, b['seq']],
        );
        if (pr.isNotEmpty && pr.first['blob'] != null) {
          for (final e in _decodeSpans(pr.first['blob'] as Uint8List)) {
            items.add({
              'seq': e.seq,
              'kind': 't',
              'num': null,
              'verse': e.verse,
              'start': e.start,
              'len': e.len,
              'style': e.style,
              'attrs': e.attrs,
              'caller': '',
              'text': e.text,
            });
          }
          items.sort((a, b) => (a['seq'] as num).compareTo(b['seq'] as num));
        }
      }
      for (final r in items) {
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
        } else if (r['kind'] == 't' && '${r['text']}'.isNotEmpty) {
          spans.add({'t': r['text'], 's': r['style'], 'a': r['attrs']});
        } else {
          spans.add(_spanJson(r));
        }
      }
      out.add({'k': _blockKind(marker), 'm': marker, 's': spans});
    }
    st.close();

    // ADR 0023: модуль без своих x-спанов получает ссылки общего слоя.
    if (_xrefLayerOn && !_moduleHasXrefs(db)) {
      await _openXrefLayer();
      _injectLayerXrefs(out, db, book, chapter);
    }

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
const _kSettings = 'sb.settings';

final _storage = web.window.localStorage;

Future<String?> bridgeSettingsLoad() async {
  final direct = _storage.getItem(_kSettings);
  if (direct != null && direct.isNotEmpty) return direct;
  // Миграция со старой записи в sb.entries, если была.
  for (final m in _entries()) {
    if (m['kind'] == 'mark' &&
        m['module'] == 'settings' &&
        m['book'] == 'SET') {
      final ctx = '${m['context'] ?? ''}';
      if (ctx.isNotEmpty) {
        _storage.setItem(_kSettings, ctx);
        return ctx;
      }
    }
  }
  return null;
}

Future<void> bridgeSettingsSave(String json) async {
  _storage.setItem(_kSettings, json);
}

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
  frag: '${m['frag'] ?? ''}',
  created: (m['created'] as num?)?.toInt() ?? 0,
  updated: (m['updated'] as num?)?.toInt() ?? 0,
);

/// Записи одного вида; module=null — по всем модулям.
Future<List<UserEntry>> bridgeEntriesList(
  String kind, {
  String? module,
}) async => [
  for (final m in _entries())
    if ((m['kind'] == kind ||
            (kind == 'hist' &&
                m['kind'] == 'mark' &&
                '${m['text'] ?? ''}'.startsWith('hist'))) &&
        (module == null || m['module'] == module))
      _toEntry(m),
];

/// Все живые записи пользователя (`hl`, `note`, `mark`, `tag`) одной главы.
Future<List<UserEntry>> bridgeEntriesChapter(
  String module,
  String book,
  int chapter,
) async => [
  for (final m in _entries())
    if (m['module'] == module &&
        m['book'] == book &&
        (m['chapter'] as num).toInt() == chapter &&
        const {'hl', 'note', 'mark', 'tag'}.contains(m['kind']) &&
        !'${m['text'] ?? ''}'.startsWith('hist'))
      _toEntry(m),
];

/// Добавить запись; id — метка времени + размер списка (достаточно для web).
/// [created] — общая метка пачки записей одного действия.
Future<String?> bridgeEntryAdd({
  required String kind,
  required String module,
  required String book,
  required int chapter,
  required int verse,
  required String text,
  required String context,
  String frag = '',
  int? created,
}) async {
  final list = _entries();
  final now = created ?? DateTime.now().millisecondsSinceEpoch;
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
    'frag': frag,
    'created': now,
    'updated': now,
  });
  _saveEntries(list);
  return id;
}

/// Диапазоны frag-селектора в тексте стиха — Dart-порт
/// `find_frag` из ядра (frag.dart).
Future<List<({int s, int e})>> bridgeFragRanges(
  String verseText,
  String frag,
) async {
  final s = fragParse(frag);
  if (s == null) return const [];
  return findFragRanges(verseText, s.exact, s.pre, s.post);
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

/// Чужие записи к стиху — на web пока нет (в.12, этап А).
Future<List<UserEntry>> bridgeEntriesForeign(
  String module,
  String book,
  int chapter,
  int verse,
) async => const [];

/// Сироты — на web relink не работает.
Future<List<String>> bridgeOrphanIds() async => const [];

/// Экспорт/импорт записей — на web нет файловой системы.
Future<int?> bridgeEntriesExport(String dest) async => null;
Future<int?> bridgeEntriesExportMd(String dest) async => null;
Future<String?> bridgeEntriesImport(String src) async => null;

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
    // Операторы запроса (зеркало crates/studybible-store::search):
    // «…» — фраза, w* — префикс, ? и внутренняя * — glob-скан
    // (FTS5 односимвольный wildcard не умеет).
    final terms = parseSearchQuery(q);
    if (terms.isEmpty) return const [];
    final hasFts = db.select(
      "SELECT count(*) AS n FROM sqlite_master WHERE name='fts' AND sql LIKE '%VIRTUAL TABLE%'",
    );
    // Встроенный индекс годится только при совпадающей версии
    // нормализации (meta.norm_version); старый — скан ниже.
    final normVer = (hasFts.first['n'] as num) > 0
        ? db.select("SELECT value AS v FROM meta WHERE key='norm_version'")
        : const [];
    final ftsOk =
        (hasFts.first['n'] as num) > 0 &&
        normVer.isNotEmpty &&
        '${normVer.first['v']}' == normVersion &&
        !terms.any((t) => t.kind == 'glob');
    if (ftsOk) {
      try {
        final rows = db.select(
          "SELECT book, chapter, verse, snippet(fts, 3, '[', ']', '…', 8) AS s"
          ' FROM fts WHERE fts MATCH ? ORDER BY rank LIMIT ?',
          [ftsQuery(terms), limit],
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
    // Скан по стихам: glob-запросы (их FTS5 не выражает) и модули
    // без рабочей fts. Лексемы проверяются по токенам
    // нормализованного текста, сниппет метит совпадения `[` `]`.
    final rows = db.select(
      'SELECT b.code, v.chapter, v.verse, v.text AS t FROM verses v '
      'JOIN books b ON b.book_id=v.book_id '
      'ORDER BY b.ord, v.chapter, v.verse',
    );
    final hits = <SearchHit>[];
    for (final r in rows) {
      final snip = scanMatch(normForIndex('${r['t']}'), terms);
      if (snip != null) {
        hits.add(
          SearchHit(
            book: '${r['code']}',
            chapter: (r['chapter'] as num).toInt(),
            verse: (r['verse'] as num?)?.toInt() ?? 0,
            snippet: snip,
          ),
        );
        if (hits.length >= limit) break;
      }
    }
    return hits;
  } catch (e) {
    debugPrint('[bridge] search $modulePath: $e');
    return const [];
  }
}

/// Поиск стихов по номеру Стронга на web: скан `span_pack`/`spans`
/// по атрибуту `strong=`. Слои `{id}-strongs` на web не поднимаем
/// (отдельный файл слоя в OPFS не ищем) — встроенной разметки
/// модуля достаточно для встроенных переводов.
Future<List<SearchHit>> bridgeModuleStrongSearch(
  String modulePath,
  String code, {
  int limit = 50,
}) async {
  try {
    final db = await _openDb(modulePath);
    final keys = _strongKeys(code);
    if (keys.isEmpty) return const [];
    var hits = _strongScan(db, keys, limit);
    if (hits.isEmpty) {
      // uW-добивка `G15100` → `G1510` — только когда точного ключа нет.
      final alt = _strongUwAltKeys(keys);
      if (alt.isNotEmpty) hits = _strongScan(db, alt, limit);
    }
    if (hits.isEmpty) {
      // Суффиксный запрос без совпадений: разметка могла проставить
      // другую букву номера (`H2300G` vs `H2300A`) — ищем базовый.
      final plain = {
        for (final k in keys)
          if (!k.endsWith(' ')) '${k.substring(0, k.length - 1)} ',
      };
      if (plain.isNotEmpty) hits = _strongScan(db, plain, limit);
    }
    return hits;
  } catch (e) {
    debugPrint('[bridge] strong search $modulePath: $e');
    return const [];
  }
}

/// Один проход сканирования разметки модуля по ключам Стронга.
List<SearchHit> _strongScan(CommonDatabase db, Set<String> keys, int limit) {
  final coords = <({String book, int chapter, int verse})>[];
  final seen = <String>{};
  void push(String book, int ch, int v) {
    if (seen.add('$book:$ch:$v')) {
      coords.add((book: book, chapter: ch, verse: v));
    }
  }

  final hasPack =
      (db.select(
            "SELECT count(*) AS n FROM sqlite_master "
            "WHERE name='span_pack' AND type='table'",
          ).first['n']
          as num) >
      0;
  if (hasPack) {
    final rows = db.select(
      'SELECT b.code AS c, p.chapter AS ch, p.blob AS blob FROM span_pack p '
      'JOIN books b ON b.book_id=p.book_id ORDER BY b.ord, p.chapter, p.block',
    );
    for (final r in rows) {
      for (final s in _decodeSpans(r['blob'] as Uint8List)) {
        final v = s.verse;
        if (v != null && _strongListHit(_attrAll(s.attrs, 'strong'), keys)) {
          push('${r['c']}', (r['ch'] as num).toInt(), v);
        }
      }
      if (coords.length >= limit) break;
    }
  } else {
    final rows = db.select(
      "SELECT b.code AS c, s.chapter AS ch, s.verse AS v, s.attrs AS a "
      'FROM spans s JOIN books b ON b.book_id=s.book_id '
      "WHERE s.kind='t' AND s.verse IS NOT NULL AND s.attrs LIKE '%strong=%' "
      'ORDER BY b.ord, s.chapter, s.verse',
    );
    for (final r in rows) {
      if (_strongListHit(_attrAll('${r['a']}', 'strong'), keys)) {
        push('${r['c']}', (r['ch'] as num).toInt(), (r['v'] as num).toInt());
      }
      if (coords.length >= limit) break;
    }
  }
  // Сниппет — нормализованный текст стиха целиком.
  return [
    for (final c in coords.take(limit))
      SearchHit(
        book: c.book,
        chapter: c.chapter,
        verse: c.verse,
        snippet: normForIndex(
          '${db.select(
                'SELECT v.text AS t FROM verses v JOIN books b ON b.book_id=v.book_id '
                'WHERE b.code=? AND v.chapter=? AND v.verse=?',
                [c.book, c.chapter, c.verse],
              ).firstOrNull?['t'] ?? ''}',
        ),
      ),
  ];
}

/// Номер Стронга → канонический ключ сравнения `H0029G`: добивка
/// нулями и регистр не влияют (`H29` ≡ `H0029`); строчные v..z при
/// 4 знаках — тёзки dStrong, регистр сохраняем. Зеркало `strong_key`
/// в crates/studybible-store/src/search.rs.
String? _strongKey(String code) {
  final s = code.trim();
  if (s.length < 2) return null;
  final prefix = s[0].toUpperCase();
  if (prefix != 'H' && prefix != 'G') return null;
  final rest = s.substring(1);
  var dlen = 0;
  while (dlen < rest.length &&
      rest.codeUnitAt(dlen) >= 0x30 &&
      rest.codeUnitAt(dlen) <= 0x39) {
    dlen++;
  }
  if (dlen == 0 || dlen > 5) return null;
  final num = int.parse(rest.substring(0, dlen));
  final tail = rest.substring(dlen);
  if (tail.length > 1) return null;
  final cu = tail.isEmpty ? 0x20 : tail.codeUnitAt(0);
  // Строчные v..z у 4-значных кодов — тёзки №22+ (dStrong, ADR 0025);
  // пустой суффикс хранится пробелом — ключ всегда «буква+цифры+суффикс».
  final suf = tail.isEmpty
      ? ' '
      : (dlen == 4 && cu >= 0x76 && cu <= 0x7a)
      ? tail
      : tail.toUpperCase();
  return '$prefix${num.toString().padLeft(4, '0')}$suf';
}

/// Ключи сравнения запроса (можно список через пробел).
Set<String> _strongKeys(String query) => {
  for (final c in query.trim().split(RegExp(r'\s+'))) ?_strongKey(c),
};

/// Варианты с uW-добивкой нулём: пятизначный `G15100` → `G1510`.
/// Применяются только когда точный ключ ничего не дал (подлинный
/// dStrong вида `G21370` ищется сначала как есть).
Set<String> _strongUwAltKeys(Set<String> keys) {
  final out = <String>{};
  for (final k in keys) {
    final digits = k.substring(1, k.length - 1);
    if (digits.length == 5 && digits.endsWith('0')) {
      out.add(
        '${k[0]}${(int.parse(digits) ~/ 10).toString().padLeft(4, '0')}'
        '${k[k.length - 1]}',
      );
    }
  }
  return out;
}

/// Список номеров через пробел (`strong` в attrs) содержит хотя бы
/// один из ключей запроса.
bool _strongListHit(String list, Set<String> keys) => list
    .split(RegExp(r'\s+'))
    .any((c) {
      final k = _strongKey(c);
      return k != null && keys.any((q) => _strongEq(q, k));
    });

/// Совпадение ключа запроса с размеченным номером: prefix+цифры
/// обязаны совпасть; суффикс запроса `' '` покрывает любые
/// dStrong-варианты (`H1254` находит и `H1254A`), суффикс-буква —
/// строгое равенство.
bool _strongEq(String query, String stored) {
  if (query.length != stored.length ||
      query.substring(0, query.length - 1) !=
          stored.substring(0, stored.length - 1)) {
    return false;
  }
  return query.endsWith(' ') || query == stored;
}

/// Все значения `key="…"` в строке атрибутов спана через пробел
/// (зеркало `attr_all` в crates/studybible-store/src/module.rs).
String _attrAll(String attrs, String key) {
  final pat = '$key="';
  final out = StringBuffer();
  var rest = attrs;
  for (;;) {
    final i = rest.indexOf(pat);
    if (i < 0) break;
    final v = rest.substring(i + pat.length);
    final j = v.indexOf('"');
    if (j < 0) break;
    if (out.isNotEmpty) out.write(' ');
    out.write(v.substring(0, j));
    rest = v.substring(j + 1);
  }
  return out.toString();
}

/// Поиск по сноскам и параллельным местам (`spans` kind
/// 'f'/'n'/'x' с текстом) — те же операторы, что и по стихам.
/// Таблица мала — всегда скан в каноническом порядке.
Future<List<SearchHit>> bridgeNotesSearch(
  String modulePath,
  String query, {
  int limit = 50,
}) async {
  try {
    final db = await _openDb(modulePath);
    final terms = parseSearchQuery(query.trim());
    if (terms.isEmpty) return const [];
    final rows = db.select(
      'SELECT b.code, s.chapter, s.verse, s.text AS t FROM spans s '
      'JOIN books b ON b.book_id=s.book_id '
      "WHERE s.kind IN ('f','n','x') AND s.text != '' "
      'ORDER BY b.ord, s.chapter, s.verse',
    );
    final hits = <SearchHit>[];
    for (final r in rows) {
      final snip = scanMatch(normForIndex('${r['t']}'), terms);
      if (snip != null) {
        hits.add(
          SearchHit(
            book: '${r['code']}',
            chapter: (r['chapter'] as num).toInt(),
            verse: (r['verse'] as num?)?.toInt() ?? 0,
            snippet: snip,
          ),
        );
        if (hits.length >= limit) break;
      }
    }
    return hits;
  } catch (e) {
    debugPrint('[bridge] notes search $modulePath: $e');
    return const [];
  }
}
