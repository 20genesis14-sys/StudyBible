/// Заглушка моста для платформ без dart:ffi (web).
///
/// На web Rust-мост недоступен: приложение читает предвыгруженные
/// JSON-ассеты (см. data.dart), а прогресс живёт только в памяти.
library;

import 'native_bridge.dart';

/// Каталог данных — в среде без файловой системы нет.
String dataDir() => '';

/// Каталог модулей .sb — на web его нет.
Future<List<SbModuleInfo>> bridgeListModules() => Future.value(const []);

/// JSON-документ модуля — на web недоступно.
Future<String?> bridgeModuleDoc(String path) => Future.value(null);

/// Глава из .sb — на web недоступно.
Future<String?> bridgeChapterDoc(String path, String book, int chapter) =>
    Future.value(null);

/// Прогресс — на web только в памяти.
Future<String?> bridgeProgressLoad() => Future.value(null);
Future<void> bridgeProgressMarkRead(String book, int chapter) async {}
Future<void> bridgeProgressSetPosition(
  String book,
  int chapter,
  int verse,
) async {}
Future<void> bridgeProgressSetVerse(
  String book,
  int chapter,
  int verse,
) async {}
Future<void> bridgeProgressReset() async {}

// ---------- записи пользователя (стаб — только в памяти) ----------

final List<UserEntry> _stubEntries = [];
int _stubSeq = 0;

Future<List<UserEntry>> bridgeEntriesList(
  String kind, {
  String? module,
}) async => [
  for (final e in _stubEntries)
    if (e.kind == kind && (module == null || e.module == module)) e,
];

Future<String?> bridgeEntryAdd({
  required String kind,
  required String module,
  required String book,
  required int chapter,
  required int verse,
  required String text,
  required String context,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final id = 'stub-${_stubSeq++}';
  _stubEntries.add(
    UserEntry(
      id: id,
      module: module,
      kind: kind,
      book: book,
      chapter: chapter,
      verse: verse,
      text: text,
      context: context,
      created: now,
      updated: now,
    ),
  );
  return id;
}

Future<bool> bridgeEntryUpdate(String id, String text) async {
  final i = _stubEntries.indexWhere((e) => e.id == id);
  if (i < 0) return false;
  final e = _stubEntries[i];
  _stubEntries[i] = UserEntry(
    id: e.id,
    module: e.module,
    kind: e.kind,
    book: e.book,
    chapter: e.chapter,
    verse: e.verse,
    text: text,
    context: e.context,
    created: e.created,
    updated: DateTime.now().millisecondsSinceEpoch,
  );
  return true;
}

Future<bool> bridgeEntryRemove(String id) async {
  final before = _stubEntries.length;
  _stubEntries.removeWhere((e) => e.id == id);
  return _stubEntries.length != before;
}

/// Перепривязка записей — стаб (вопрос №12; на этой платформе нет).
Future<String?> bridgeEntriesRelink() async => null;

// ---------- словарь (стаб — пусто) ----------

Future<List<DictEntryInfo>> bridgeDictEntries(
  String path, {
  int offset = 0,
  int limit = 200,
  String prefix = '',
}) async => const [];

Future<DictArticleInfo?> bridgeDictEntry(String path, int ord) async => null;

// ---------- поиск (стаб — пусто) ----------

Future<List<SearchHit>> bridgeModuleSearch(
  String modulePath,
  String query, {
  int limit = 50,
}) async => const [];
