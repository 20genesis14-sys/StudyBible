/// End-to-end проверка моста: чтение настоящего .sb-модуля и прогресса
/// через Rust-ядро (flutter_rust_bridge).
///
/// Запуск:
///   STUDYBIBLE_DATA=~/StudyBible-data flutter test test/bridge_test.dart
///
/// Если .so не собран build-хуком, каталог с ней можно указать через
/// FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR. Без каталога данных тесты
/// пропускаются — фоллбэк на JSON-ассеты проверяет widget_test.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/data.dart';
import 'package:studybible/models.dart';
import 'package:studybible/native_bridge_io.dart';
import 'package:studybible/state.dart';

bool _hasSb() {
  final dir = Platform.environment['STUDYBIBLE_DATA'];
  if (dir == null) return false;
  return File(
    '$dir${Platform.pathSeparator}modules${Platform.pathSeparator}russyn.sb',
  ).existsSync();
}

/// Плоский текст главы — собираем TextSpanDoc подряд.
String _plain(ChapterDoc ch) => [
  for (final b in ch.blocks)
    for (final s in b.spans)
      if (s is TextSpanDoc) s.text,
].join();

void main() {
  // Биндинг нужен для фоллбэка на JSON-ассеты, если мост не поднялся.
  TestWidgetsFlutterBinding.ensureInitialized();
  final hasSb = _hasSb();

  test('каталог модуля russyn.sb читается через мост', () async {
    final doc = await loadModule('russyn');
    // Источник обязан быть .sb (не JSON-фоллбэк): ленивый загрузчик глав.
    expect(
      doc.chapterLoader,
      isNotNull,
      reason: 'ожидался .sb-документ через мост, а не JSON-ассет',
    );
    expect(doc.id, 'russyn');
    expect(doc.books.length, 66);
    expect(doc.bookByCode('GEN')!.chapters, 50);
    // Число стихов главы для экрана выбора стиха.
    expect(doc.verseCount('GEN', 1), 31);
  }, skip: hasSb ? false : 'нет STUDYBIBLE_DATA/modules/russyn.sb');

  test('глава читается из .sb end-to-end', () async {
    final doc = await loadModule('russyn');
    final ch = await doc.ensureChapter('GEN', 1);
    expect(ch, isNotNull);
    expect(ch!.blocks, isNotEmpty);
    // Синодальный перевод: «В начале сотворил Бог небо и землю».
    expect(_plain(ch), contains('начале'));
    // Повторная подгрузка — из кэша, та же глава.
    expect(await doc.ensureChapter('GEN', 1), same(ch));
    // Несуществующая глава — null, без падения.
    expect(await doc.ensureChapter('GEN', 51), isNull);
  }, skip: hasSb ? false : 'нет .sb');

  test('прогресс сохраняется и читается через UserData', () async {
    await bridgeProgressReset();
    await bridgeProgressMarkRead('GEN', 1);
    await bridgeProgressSetPosition('EXO', 3, 2);
    await bridgeProgressSetVerse('GEN', 1, 7);

    final p = ReadProgress();
    await p.load();
    expect(p.isRead('GEN', 1), isTrue);
    expect(p.lastPosition, 'EXO:3');
    expect(p.lastVerse['GEN:1'], 7);

    await bridgeProgressReset();
    final p2 = ReadProgress();
    await p2.load();
    expect(p2.read, isEmpty);
    expect(p2.lastPosition, isNull);
  }, skip: hasSb ? false : 'нет .sb');

  test('записи пользователя: добавить/изменить/удалить', () async {
    final id = await bridgeEntryAdd(
      kind: 'note',
      module: 'russyn',
      book: 'GEN',
      chapter: 1,
      verse: 1,
      text: 'тестовая заметка',
      context: 'В начале',
    );
    expect(id, isNotNull);
    final hid = await bridgeEntryAdd(
      kind: 'hl',
      module: 'russyn',
      book: 'GEN',
      chapter: 1,
      verse: 3,
      text: 'yellow',
      context: '',
    );
    expect(hid, isNotNull);

    var notes = await bridgeEntriesList('note', module: 'russyn');
    final note = notes.where((e) => e.id == id).single;
    expect(note.book, 'GEN');
    expect(note.verse, 1);
    expect(note.text, 'тестовая заметка');

    expect(await bridgeEntryUpdate(id!, 'правка'), isTrue);
    notes = await bridgeEntriesList('note', module: 'russyn');
    expect(notes.where((e) => e.id == id).single.text, 'правка');

    expect(await bridgeEntryRemove(id), isTrue);
    expect(await bridgeEntryRemove(hid!), isTrue);
    notes = await bridgeEntriesList('note', module: 'russyn');
    expect(notes.where((e) => e.id == id), isEmpty);
  }, skip: hasSb ? false : 'нет .sb');

  test('поиск по модулю находит стих', () async {
    final path =
        modulePathOf('russyn') ??
        '${Platform.environment['STUDYBIBLE_DATA']}/modules/russyn.sb';
    final hits = await bridgeModuleSearch(path, 'любви', limit: 10);
    expect(hits, isNotEmpty);
    expect(hits.first.book, isNotEmpty);
    expect(hits.first.snippet.toLowerCase(), contains('любв'));
  }, skip: hasSb ? false : 'нет .sb');

  test('история чтения: запись и возврат', () async {
    await history.load();
    final before = history.items.length;
    await history.touch('russyn', 'JHN', 3);
    // Повторное посещение — одна запись, свежая метка.
    await history.touch('russyn', 'JHN', 3);
    final jhn = history.items
        .where((e) => e.module == 'russyn' && e.book == 'JHN' && e.chapter == 3)
        .toList();
    expect(jhn.length, 1);
    expect(history.items.length, before + 1);
    // Очистка тестовой записи.
    await bridgeEntryRemove(jhn.first.id);
    await history.load();
  }, skip: hasSb ? false : 'нет .sb');
}
