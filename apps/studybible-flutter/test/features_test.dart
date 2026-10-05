/// Расширенный испытательный набор: настройки и основной перевод,
/// сквозная история (главы/словарь/поиск), закладки и теги,
/// поиск по другим модулям, словарь Стронга.
///
/// Покрывает то, чего не было в bridge_test.dart: там проверялись
/// чтение модуля, прогресс, заметки/выделения и запись истории глав.
///
/// Запуск:
///   STUDYBIBLE_DATA=~/StudyBible-data flutter test test/features_test.dart
///
/// Чистые юнит-тесты (mainModuleId, значения Settings по умолчанию) идут
/// без каталога данных; мостовые пропускаются, если .sb нет.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/data.dart';
import 'package:studybible/lexicon.dart';
import 'package:studybible/native_bridge_io.dart';
import 'package:studybible/state.dart';
import 'package:studybible/theme.dart';

bool _hasSb() {
  final dir = Platform.environment['STUDYBIBLE_DATA'];
  if (dir == null) return false;
  return File(
    '$dir${Platform.pathSeparator}modules${Platform.pathSeparator}russyn.sb',
  ).existsSync();
}

String _sbPath(String id) =>
    '${Platform.environment['STUDYBIBLE_DATA']}/modules/$id.sb';

/// Убрать все тестовые записи истории после прогона.
Future<void> _cleanupHistory() async {
  final all = await bridgeEntriesList('mark');
  for (final e in all.where(
    (e) =>
        e.text.startsWith('hist') &&
        (e.context.contains('ТЕСТ') ||
            e.module == 'search' && e.context == 'тест-запрос'),
  )) {
    await bridgeEntryRemove(e.id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hasSb = _hasSb();

  group('основной перевод (без моста)', () {
    final saved = settings.defaultModule;
    tearDown(() => settings.defaultModule = saved);

    test('mainModuleId возвращает настройку', () {
      settings.defaultModule = 'engwebp';
      expect(mainModuleId(), 'engwebp');
      settings.defaultModule = 'russyn';
      expect(mainModuleId(), 'russyn');
    });

    test('неизвестный id откатывается на доступный модуль', () {
      settings.defaultModule = 'nonexistent-xyz';
      expect(mainModuleId(), 'russyn');
    });

    test('значения Settings по умолчанию не изменились', () {
      final s = Settings();
      expect(s.defaultModule, 'russyn');
      expect(s.theme, AppTheme.light);
      expect(s.fontScale, 1.0);
      expect(s.lang, 'ru');
      expect(s.versePickerEnabled, isFalse);
    });
  });

  group('настройки сохраняются', () {
    test('Settings.update пишет JSON, новый экземпляр его читает', () async {
      // Сохранить прежние настройки, если были.
      final before = (await bridgeEntriesList('mark'))
          .where((e) => e.module == 'settings' && e.book == 'SET')
          .toList();

      await settings.load();
      settings.update(() {
        settings.defaultModule = 'engwebp';
        settings.fontScale = 1.3;
        settings.theme = AppTheme.dark;
        settings.versePickerEnabled = true;
      });
      // _save() из update() не ждётся — даём мосту записать.
      await Future.delayed(const Duration(milliseconds: 500));

      final s2 = Settings();
      await s2.load();
      expect(s2.defaultModule, 'engwebp');
      expect(s2.fontScale, closeTo(1.3, 0.001));
      expect(s2.theme, AppTheme.dark);
      expect(s2.versePickerEnabled, isTrue);

      // Откат: удалить тестовую запись и вернуть прежние, если были.
      for (final e in (await bridgeEntriesList(
        'mark',
      )).where((e) => e.module == 'settings' && e.book == 'SET')) {
        await bridgeEntryRemove(e.id);
      }
      for (final e in before) {
        await bridgeEntryAdd(
          kind: e.kind,
          module: e.module,
          book: e.book,
          chapter: e.chapter,
          verse: e.verse,
          text: e.text,
          context: e.context,
        );
      }
      settings.defaultModule = 'russyn';
      settings.fontScale = 1.0;
      settings.theme = AppTheme.light;
      settings.versePickerEnabled = false;
    }, skip: hasSb ? false : 'нет STUDYBIBLE_DATA');
  });

  group('сквозная история', () {
    tearDownAll(() async {
      if (hasSb) await _cleanupHistory();
    });

    test('статья словаря: touchDict пишет hist:dict и дедуплицирует', () async {
      await history.load();
      await history.touchDict('H9999', 'ТЕСТ-слово');
      await history.touchDict('H9999', 'ТЕСТ-слово'); // повтор — не дубль
      await history.touchDict('H9999', 'ТЕСТ-переименовано'); // тот же номер

      final d = history.items.where(
        (e) => e.text == 'hist:dict' && e.context.startsWith('H9999|'),
      );
      expect(d.length, 1);
      expect(d.first.module, 'lexicon');
      expect(d.first.book, 'LEX');
      expect(d.first.context, 'H9999|ТЕСТ-переименовано');
    }, skip: hasSb ? false : 'нет .sb');

    test('поисковый запрос: touchSearch пишет hist:search', () async {
      await history.load();
      await history.touchSearch('тест-запрос');
      await history.touchSearch('тест-запрос'); // дедуп по запросу
      await history.touchSearch('  '); // пустой не пишется

      final s = history.items.where(
        (e) => e.text == 'hist:search' && e.context == 'тест-запрос',
      );
      expect(s.length, 1);
      expect(s.first.module, 'search');
      expect(s.first.book, 'SRH');
      expect(
        history.items.where(
          (e) => e.text == 'hist:search' && e.context.isEmpty,
        ),
        isEmpty,
      );
    }, skip: hasSb ? false : 'нет .sb');

    test('глава в разных переводах — разные записи истории', () async {
      await history.load();
      await history.touch('russyn', 'JOB', 1, verse: 0);
      // Тот же стих в другом переводе — отдельная запись, не дубль.
      await history.touch('engwebp', 'JOB', 1);
      await history.touch('engwebp', 'JOB', 1); // повтор — дедуп

      final ru = history.items.where(
        (e) => e.text == 'hist' && e.module == 'russyn' && e.book == 'JOB',
      );
      final en = history.items.where(
        (e) => e.text == 'hist' && e.module == 'engwebp' && e.book == 'JOB',
      );
      expect(ru.length, 1);
      expect(en.length, 1);

      // Чистим тестовые записи.
      for (final e in [...ru, ...en]) {
        await bridgeEntryRemove(e.id);
      }
    }, skip: hasSb ? false : 'нет .sb');

    test('закладки (mark без hist) не попадают в историю', () async {
      final id = await bridgeEntryAdd(
        kind: 'mark',
        module: 'russyn',
        book: 'PSA',
        chapter: 23,
        verse: 1,
        text: '',
        context: '',
      );
      expect(id, isNotNull);

      await history.load();
      expect(
        history.items.any((e) => e.id == id),
        isFalse,
        reason: 'закладка не должна показываться в истории',
      );
      await bridgeEntryRemove(id!);
    }, skip: hasSb ? false : 'нет .sb');
  });

  group('записи пользователя — непокрытые виды', () {
    final ids = <String>[];
    tearDownAll(() async {
      if (!hasSb) return;
      for (final id in ids) {
        await bridgeEntryRemove(id);
      }
    });

    test('закладка (mark) добавляется и читается', () async {
      final id = await bridgeEntryAdd(
        kind: 'mark',
        module: 'russyn',
        book: 'PSA',
        chapter: 23,
        verse: 4,
        text: '',
        context: 'тень смертная',
      );
      expect(id, isNotNull);
      ids.add(id!);

      final marks = await bridgeEntriesList('mark', module: 'russyn');
      final m = marks.where((e) => e.id == id).single;
      expect(m.book, 'PSA');
      expect(m.verse, 4);
      expect(m.text, isEmpty);
    }, skip: hasSb ? false : 'нет .sb');

    test('тег (tag) добавляется и читается', () async {
      final id = await bridgeEntryAdd(
        kind: 'tag',
        module: 'russyn',
        book: 'JHN',
        chapter: 3,
        verse: 16,
        text: 'любовь',
        context: '',
      );
      expect(id, isNotNull);
      ids.add(id!);

      final tags = await bridgeEntriesList('tag', module: 'russyn');
      expect(tags.any((e) => e.id == id && e.text == 'любовь'), isTrue);
    }, skip: hasSb ? false : 'нет .sb');

    test('entryUpdate/entryRemove на несуществующем id не падают', () async {
      expect(await bridgeEntryUpdate('no-such-id-999', 'x'), isFalse);
      expect(await bridgeEntryRemove('no-such-id-999'), isFalse);
    }, skip: hasSb ? false : 'нет .sb');
  });

  group('поиск по другим модулям', () {
    test('engwebp находит английский текст', () async {
      final hits = await bridgeModuleSearch(
        _sbPath('engwebp'),
        'beginning',
        limit: 5,
      );
      expect(hits, isNotEmpty);
      expect(hits.length, lessThanOrEqualTo(5));
      expect(hits.first.snippet.toLowerCase(), contains('beginning'));
    }, skip: hasSb ? false : 'нет .sb');

    test('пустой результат на бессмысленный запрос — не ошибка', () async {
      final hits = await bridgeModuleSearch(
        _sbPath('russyn'),
        'zzzqqqййй',
        limit: 5,
      );
      expect(hits, isEmpty);
    }, skip: hasSb ? false : 'нет .sb');
  });

  group('словарь Стронга', () {
    test('английский словарь загружается из ассетов', () async {
      final d = await lexicon();
      expect(d.length, greaterThan(10000));
      final e = d['H3117'];
      expect(e, isNotNull);
      expect(e!.lemma, isNotEmpty);
    });
  });
}
