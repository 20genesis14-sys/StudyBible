import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/data.dart';
import 'package:studybible/l10n.dart';
import 'package:studybible/state.dart';
import 'package:studybible/theme.dart';

void main() {
  group('Settings', () {
    test('compareList: пусто → все известные модули', () {
      final s = Settings()..compareModules = '';
      expect(s.compareList, unorderedEquals(kModules.keys));
    });

    test('compareList: явный список фильтрует неизвестные id', () {
      final s = Settings()..compareModules = 'russyn,kjv2006,no-such-id';
      expect(s.compareList, ['russyn', 'kjv2006']);
    });

    test('xrefModuleOrMain: пусто → основной перевод, задано → оно', () {
      final s = Settings()..xrefModule = '';
      expect(s.xrefModuleOrMain, mainModuleId());
      s.xrefModule = 'engwebp';
      expect(s.xrefModuleOrMain, 'engwebp');
    });

    test('update уведомляет слушателей', () {
      final s = Settings();
      var notified = 0;
      s.addListener(() => notified++);
      s.update(() => s.theme = AppTheme.dark);
      expect(s.theme, AppTheme.dark);
      expect(notified, 1);
    });

    test('mainModuleId: неизвестный defaultModule → russyn', () {
      settings.update(() => settings.defaultModule = 'no-such');
      expect(mainModuleId(), 'russyn');
      settings.update(() => settings.defaultModule = 'engwebp');
      expect(mainModuleId(), 'engwebp');
      settings.update(() => settings.defaultModule = 'russyn');
    });

    test('load без данных/при ошибке моста — дефолты не падают', () async {
      final s = Settings();
      await s.load();
      expect(s.theme, AppTheme.light);
      expect(s.fontScale, 1.0);
      expect(s.lang, 'ru');
      expect(s.readerMode, ReaderMode.reading);
      expect(s.layerFootnotes, isTrue);
    });
  });

  group('ReadProgress', () {
    test('markRead / isRead / readCount', () {
      final p = ReadProgress();
      p.markRead('GEN', 1);
      p.markRead('GEN', 2);
      p.markRead('EXO', 1);
      expect(p.isRead('GEN', 1), isTrue);
      expect(p.isRead('GEN', 3), isFalse);
      expect(p.readCount('GEN'), 2);
      expect(p.readCount('EXO'), 1);
    });

    test('setPosition / setVerse / reset', () {
      final p = ReadProgress();
      p.setPosition('GEN', 1);
      p.setVerse('GEN', 1, 7);
      expect(p.lastPosition, 'GEN:1');
      expect(p.lastVerse['GEN:1'], 7);
      p.reset();
      expect(p.lastPosition, isNull);
      expect(p.read, isEmpty);
      expect(p.lastVerse, isEmpty);
    });
  });

  group('Notes', () {
    test('add: пустая и whitespace-заметка не добавляется', () async {
      final n = Notes();
      await n.add('');
      await n.add('   ');
      expect(n.items, isEmpty);
    });

    test('add обрезает пробелы и вставляет сверху', () async {
      final n = Notes();
      await n.add('  первая  ');
      await n.add('вторая');
      expect(n.items, hasLength(2));
      expect(n.items[0].text, 'вторая');
      expect(n.items[1].text, 'первая');
    });

    test('remove удаляет запись', () async {
      final n = Notes();
      await n.add('x');
      await n.remove(n.items.single);
      expect(n.items, isEmpty);
    });
  });

  group('ReadingHistory', () {
    test('touch: повтор главы обновляет запись, а не плодит', () async {
      final h = ReadingHistory();
      await h.touch('russyn', 'GEN', 1);
      await h.touch('russyn', 'GEN', 1, verse: 5);
      final gen1 = h.items.where(
        (e) => e.text == 'hist' && e.book == 'GEN' && e.chapter == 1,
      );
      expect(gen1, hasLength(1));
      expect(gen1.single.verse, 5);
    });

    test('разные главы — разные записи; свежая сверху', () async {
      final h = ReadingHistory();
      await h.touch('russyn', 'GEN', 1);
      await h.touch('russyn', 'GEN', 2);
      expect(
        h.items.where((e) => e.text == 'hist'),
        hasLength(2),
      );
      expect(h.items.first.chapter, 2);
    });

    test('touchSearch: пустой запрос игнорируется, повтор дедупится', () async {
      final h = ReadingHistory();
      await h.touchSearch('   ');
      expect(h.items.where((e) => e.text == 'hist:search'), isEmpty);
      await h.touchSearch('любовь');
      await h.touchSearch('любовь');
      expect(h.items.where((e) => e.text == 'hist:search'), hasLength(1));
      expect(h.items.first.context, 'любовь');
    });

    test('touchDict: дедуп по номеру Стронга', () async {
      final h = ReadingHistory();
      await h.touchDict('H7225', 'решит');
      await h.touchDict('H7225', 'решит');
      await h.touchDict('G25', 'агапе');
      expect(h.items.where((e) => e.text == 'hist:dict'), hasLength(2));
    });
  });

  group('l10n', () {
    test('tr выбирает ru/en по settings.lang', () {
      settings.update(() => settings.lang = 'ru');
      expect(tr('Настройки', 'Settings'), 'Настройки');
      settings.update(() => settings.lang = 'en');
      expect(tr('Настройки', 'Settings'), 'Settings');
      settings.update(() => settings.lang = 'ru');
    });
  });

  group('каталог книг', () {
    test('66 книг, уникальные коды, ВЗ 39 + НЗ 27', () {
      expect(kCatalog, hasLength(66));
      expect(kCatalog.map((e) => e.$1).toSet(), hasLength(66));
      expect(bookIndexOf('MAT'), kNtFirstIndex);
      expect(bookIndexOf('XXX'), -1);
      expect(kShortName['PSA'], 'Пс');
      expect(kBookGroup.containsKey('REV'), isTrue);
    });
  });
}
