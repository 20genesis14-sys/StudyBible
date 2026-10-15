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

import 'dart:convert';
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

  test('общий слой параллельных подмешивается модулю без x-спанов', () async {
    // ADR 0023: russyn без собственных ссылок получает openbible-xrefs.
    final dir = Platform.environment['STUDYBIBLE_DATA']!;
    final hasLayer =
        File('$dir${Platform.pathSeparator}modules${Platform.pathSeparator}openbible-xrefs.sb')
            .existsSync() ||
        File('$dir${Platform.pathSeparator}modules${Platform.pathSeparator}openbible-xrefs.sbz')
            .existsSync();
    if (!hasLayer) return; // слоя нет — тест неприменим

    await bridgeSetXrefLayer(true);
    final doc = await loadModule('russyn');
    final ch = await doc.ensureChapter('GEN', 1);
    final xnotes = [
      for (final b in ch!.blocks)
        for (final s in b.spans)
          if (s is NoteSpanDoc && s.kind == 'x') s,
    ];
    expect(xnotes, isNotEmpty, reason: 'слой должен дать x-спаны в Быт 1');
    // Текст ссылок слоя — OSIS-аббревиатуры.
    expect(xnotes.first.text, contains('John 1:1'));

    // Отключено — та же глава без параллельных.
    await bridgeSetXrefLayer(false);
    final raw2 =
        await bridgeChapterDoc(modulePathOf('russyn')!, 'GEN', 1);
    expect(raw2, isNotNull);
    final parsed = ChapterDoc.fromJson(
      jsonDecode(raw2!) as Map<String, dynamic>,
    );
    expect(
      parsed.blocks
          .expand((b) => b.spans)
          .whereType<NoteSpanDoc>()
          .where((n) => n.kind == 'x'),
      isEmpty,
    );
    await bridgeSetXrefLayer(true);
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

  test('Фаза 4: подстрочник step-orig (Быт 1, Пс 23, Ин 1), слой engbsb-strongs и карточки', () async {
    await rescanModules();
    final origPath = modulePathOf('step-orig');
    if (origPath == null) return;

    final orig = await loadModule('step-orig');
    for (final (bk, chN, wordExpected) in [
      ('GEN', 1, 'beginning'),
      ('PSA', 23, 'shepherd'),
      ('JHN', 1, 'Word'),
    ]) {
      final ch = await orig.ensureChapter(bk, chN);
      expect(ch, isNotNull, reason: 'ожидалась глава $bk $chN в step-orig');
      expect(_plain(ch!), contains(wordExpected));
      final dg = await bridgeChapterDoc(origPath, '@dict_glosses:$bk', chN);
      expect(dg, isNotNull);
      expect(dg!, contains('"glosses"'));
    }

    // Проверка наложения слоя engbsb-strongs v0.4.0 на engbsb.sb:
    // В Быт 1:1 первое слово 'In' обязано получить dStrong 'H9003' (вместо старого eBible 'H8064').
    final bsb = await loadModule('engbsb');
    final bsbGen1 = await bsb.ensureChapter('GEN', 1);
    expect(bsbGen1, isNotNull);
    final firstW = bsbGen1!.blocks
        .expand((b) => b.spans)
        .whereType<TextSpanDoc>()
        .firstWhere((s) => s.strong != null);
    expect(firstW.text, 'In');
    expect(firstW.strong, 'H9003');
    expect(firstW.flags, contains('aux'));

    // Проверка надписания Псалма 3 (BlockKind.superscription, verse 0):
    // слово 'Absalom' должно иметь dStrong 'H0053' и открывать карточку сущности Absalom.
    final bsbPsa3 = await bsb.ensureChapter('PSA', 3);
    expect(bsbPsa3, isNotNull);
    final supBlock = bsbPsa3!.blocks.firstWhere(
      (b) => b.kind == BlockKind.superscription,
    );
    final absalomSpan = supBlock.spans
        .whereType<TextSpanDoc>()
        .firstWhere((s) => s.text == 'Absalom');
    expect(absalomSpan.strong, 'H0053');
    final absalomCard = await bridgeChapterDoc(
      origPath,
      '@lex:${absalomSpan.strong}|ref=${absalomSpan.refAddr ?? ""}',
      1,
    );
    expect(absalomCard, isNotNull);
    expect(absalomCard!, contains('Absalom'));

    // Проверка расширенной карточки лексикона и графа знаний (@lex и @entity).
    final lexRaw = await bridgeChapterDoc(
      origPath,
      '@lex:H0430G|ref=Gen.1.1#03',
      1,
    );
    expect(lexRaw, isNotNull);
    final lexJson = jsonDecode(lexRaw!) as Map<String, dynamic>;
    expect((lexJson['entries'] as List), isNotEmpty);
    expect(lexJson['entity'], isNotNull);

    // Проверка ORIG-3: на многоморфемном слове Gen.1.1#01 ('בְּרֵאשִׁית')
    // запрос H7225G возвращает морфологию существительного ('Ncfsa'), а не предлога ('HR').
    final begRaw = await bridgeChapterDoc(
      origPath,
      '@lex:H7225G|ref=Gen.1.1#01',
      1,
    );
    expect(begRaw, isNotNull);
    final begJson = jsonDecode(begRaw!) as Map<String, dynamic>;
    expect(begJson['context_sense'], '1_beginning');
    expect((begJson['morph'] as List).first['code'], 'Ncfsa');

    // Проверка ORIG-1: пророк Захария в Зах 1:1 (Zec.1.1#10) сохраняет строчный суффикс H2148v
    // и открывает карточку именно пророка Захарии (person:Zechariah.17).
    final zecRaw = await bridgeChapterDoc(
      origPath,
      '@lex:H2148v|ref=Zec.1.1#10',
      1,
    );
    expect(zecRaw, isNotNull);
    final zecJson = jsonDecode(zecRaw!) as Map<String, dynamic>;
    expect((zecJson['entries'] as List).first['key'], 'H2148v');
    expect((zecJson['entity'] as Map<String, dynamic>)['id'], 'person:Zechariah.17');

    final entRaw = await bridgeChapterDoc(origPath, '@entity:person:Abraham', 1);
    expect(entRaw, isNotNull);
    expect(entRaw!, contains('Abraham'));
    final entJson = jsonDecode(entRaw) as Map<String, dynamic>;
    expect((entJson['names_ru'] as List), contains('Авраам'));
    expect((entJson['short_description_ru'] as String).isNotEmpty, isTrue);
    expect((entJson['name_meaning_ru'] as String).isNotEmpty, isTrue);

    final cubitRaw = await bridgeChapterDoc(origPath, '@entity:realia:Cubit', 1);
    expect(cubitRaw, isNotNull);
    expect(cubitRaw!, contains('44,5 см'));

    final bcRaw = await bridgeChapterDoc(origPath, '@book_chronology:HAB', 1);
    expect(bcRaw, isNotNull);
    final bcJson = jsonDecode(bcRaw!) as Map<String, dynamic>;
    final bcBooks = (bcJson['books'] as List).cast<Map<String, dynamic>>();
    expect(bcBooks.length, 66);
    expect(bcBooks.firstWhere((b) => b['book'] == 'HAB')['state'], 1);
    expect(bcBooks.firstWhere((b) => b['book'] == 'GEN')['state'], 2);
    expect(bcBooks.firstWhere((b) => b['book'] == 'PSA')['state'], 3);
    expect(bcBooks.firstWhere((b) => b['book'] == 'MAL')['state'], 4);

    final vaRaw = await bridgeChapterDoc(origPath, '@visual_aid:35B', 1);
    expect(vaRaw, isNotNull);
    expect(vaRaw!, contains('HAB.2.4'));

    // Фаза 8: проверка русского словаря strongs-step-ru, русского словарного
    // подстрочника и наложения слоёв russyn-strongs и ru_rlob-strongs.
    final dgRu = await bridgeChapterDoc(origPath, '@dict_glosses:GEN|lang=ru', 1);
    expect(dgRu, isNotNull);
    expect(dgRu!.toLowerCase(), contains('начал'));

    final lexRu = await bridgeChapterDoc(origPath, '@lex:G5057|lang=ru', 1);
    expect(lexRu, isNotNull);
    expect(lexRu!, contains('сборщик налогов'));
    expect(lexRu, contains('мытарь'));

    // Проверка исправления H0430G (Бог) и G5547 (Христос) в strongs-step-ru.sb:
    // H0430G обязан иметь глосс 'Бог', статью 'Бог, Божий' (не 'ангел') и русский домен.
    final elohimRu = await bridgeChapterDoc(origPath, '@lex:H0430G|lang=ru', 1);
    expect(elohimRu, isNotNull);
    final elohimJson = jsonDecode(elohimRu!) as Map<String, dynamic>;
    final elohimEntry = (elohimJson['entries'] as List).first as Map<String, dynamic>;
    expect(elohimEntry['gloss'], 'Бог');
    expect(elohimEntry['sense_domain'], contains('Бога'));
    expect(elohimRu, contains('Бог, Божий'));
    expect(elohimRu.contains('ангел, ангелы, архангел'), isFalse);

    final christRu = await bridgeChapterDoc(origPath, '@lex:G5547|lang=ru', 1);
    expect(christRu, isNotNull);
    final christJson = jsonDecode(christRu!) as Map<String, dynamic>;
    final christEntry = (christJson['entries'] as List).first as Map<String, dynamic>;
    expect(christEntry['gloss'], contains('Христос'));

    final syn = await loadModule('russyn');
    final synGen1 = await syn.ensureChapter('GEN', 1);
    expect(synGen1, isNotNull);
    final synWords = synGen1!.blocks
        .expand((b) => b.spans)
        .whereType<TextSpanDoc>()
        .where((s) => s.strong != null)
        .toList();
    expect(synWords.first.text, 'В');
    expect(synWords.first.strong, 'H9003');
    expect(synWords[1].text, 'начале');
    expect(synWords[1].strong, 'H7225G');
  }, skip: hasSb ? false : 'нет .sb');
}
