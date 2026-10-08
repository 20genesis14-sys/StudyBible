import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/data.dart';
import 'package:studybible/native_bridge_io.dart';
import 'package:studybible/l10n.dart';
import 'package:studybible/state.dart';
import 'package:studybible/theme.dart';

void main() {
  group('Settings', () {
    test('compareList: пусто → все установленные модули', () async {
      // Список строится из реального скана каталога данных
      // (решение 08.10.2026: только установленные модули).
      await rescanModules();
      final s = Settings()..compareModules = '';
      expect(s.compareList, unorderedEquals(installedModules.keys));
    });

    test('compareList: явный список фильтрует неустановленные id',
        () async {
      await rescanModules();
      final s = Settings()
        ..compareModules = 'russyn,no-such-id';
      expect(s.compareList, ['russyn']);
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

    test('mainModuleId: неизвестный defaultModule → russyn', () async {
      await rescanModules();
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

    test('настройки голоса: дефолты новых полей', () async {
      final s = Settings();
      await s.load();
      // Автоударения включены по умолчанию, движок/голос — системные.
      expect(s.voiceAccent, isTrue);
      expect(s.systemEngine, '');
      expect(s.systemVoice, '');
    });

    test('поля голоса пишутся update (без load — только память)', () {
      // Не загружаем: _loaded=false → update не сохраняет в userdata.
      final s = Settings();
      s.update(() {
        s.voiceAccent = false;
        s.systemEngine = 'com.example.tts';
        s.systemVoice = 'v|ru-RU';
      });
      expect(s.voiceAccent, isFalse);
      expect(s.systemEngine, 'com.example.tts');
      expect(s.systemVoice, 'v|ru-RU');
    });

    test('voiceAccent/systemEngine/systemVoice: roundtrip через UserData',
        () async {
      // FLUTTER_TEST=true → userdata.db во временном каталоге,
      // реальная база пользователя не трогается.
      final s = Settings();
      await s.load();
      s.update(() {
        s.voiceAccent = false;
        s.systemEngine = 'com.test.tts';
        s.systemVoice = 'test-voice|ru-RU';
      });
      // _save() — fire-and-forget: ждём, пока запись появится в БД.
      var saved = false;
      for (var i = 0; i < 100 && !saved; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final all = await bridgeEntriesList('mark');
        saved = all.any(
          (e) =>
              e.module == 'settings' &&
              e.book == 'SET' &&
              e.context.contains('com.test.tts'),
        );
      }
      expect(saved, isTrue, reason: 'настройки не записались в UserData');

      final s2 = Settings();
      await s2.load();
      expect(s2.voiceAccent, isFalse);
      expect(s2.systemEngine, 'com.test.tts');
      expect(s2.systemVoice, 'test-voice|ru-RU');

      // Чистим за собой: temp-база общая на весь прогон тестов.
      s2.update(() {
        s2.voiceAccent = true;
        s2.systemEngine = '';
        s2.systemVoice = '';
      });
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final all = await bridgeEntriesList('mark');
        final ok = all.every(
          (e) =>
              !(e.module == 'settings' && e.book == 'SET') ||
              !e.context.contains('com.test.tts'),
        );
        if (ok) break;
      }
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
      await n.add('', '');
      await n.add('   ', '   ');
      expect(n.items, isEmpty);
    });

    test('add обрезает пробелы и вставляет сверху', () async {
      final n = Notes();
      await n.add('', '  первая  ');
      await n.add('заголовок', 'вторая');
      expect(n.items, hasLength(2));
      expect(n.items[0].text, 'вторая');
      expect(n.items[0].title, 'заголовок');
      expect(n.items[1].text, 'первая');
    });

    test('edit меняет заголовок и текст', () async {
      final n = Notes();
      await n.add('t', 'b');
      await n.edit(n.items.single, 'новое', 'новый текст');
      expect(n.items.single.title, 'новое');
      expect(n.items.single.text, 'новый текст');
    });

    test('remove удаляет запись', () async {
      final n = Notes();
      await n.add('', 'x');
      await n.remove(n.items.single);
      expect(n.items, isEmpty);
    });

    test('splitNote/joinNote: формат «заголовок\\x1Fтекст»', () {
      expect(joinNote('', 'тело'), 'тело');
      expect(joinNote('заг', 'тело'), 'заг\x1Fтело');
      expect(splitNote('тело без заголовка'), ('', 'тело без заголовка'));
      expect(splitNote('заг\x1Fтело'), ('заг', 'тело'));
      expect(splitNote('заг\x1F'), ('заг', ''));
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
