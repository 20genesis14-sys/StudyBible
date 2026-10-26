/// Замеры рендер-кэша строк главы (ADR 0030, шаг «до/после»).
///
/// Настоящий ReadingScreen на самой длинной главе Псалтири
/// (engbsb → PSA 119, 176 стихов; без него russyn → PSA 118) в режиме
/// «Изучение»: холодная сборка главы, 20 горячих пересборок экрана
/// (нотификации настроек) и дым ленты «книга» с такими же горячими
/// пересборками. Кэш отключается компиляционным флагом — поведение
/// как до ADR 0030:
///
///   STUDYBIBLE_DATA=D:/StudyBible-data flutter test test/render_bench_test.dart
///   STUDYBIBLE_DATA=D:/StudyBible-data flutter test \
///     --dart-define=STUDYBIBLE_NO_RENDER_CACHE=true test/render_bench_test.dart
///
/// Абсолютные числа — свойства тестовой среды (FakeAsync-кадры, без
/// GPU-рендера); осмысленно сравнивать только отношения режимов
/// ON/OFF внутри одинакового прогона. Замеритель, не тест-критерий:
/// цифры печатаются с префиксом BENCH, без каталога данных тест
/// пропускается.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/data.dart';
import 'package:studybible/reader/line_cache.dart'
    show ChapterLineCache, kRenderCacheDisabled;
import 'package:studybible/screens/reading_screen.dart';
import 'package:studybible/state.dart';
import 'package:studybible/theme.dart';

String get _dataDir => Platform.environment['STUDYBIBLE_DATA'] ?? '';

String _modulePath(String id) =>
    '$_dataDir${Platform.pathSeparator}modules${Platform.pathSeparator}$id.sb';

int _ms(Stopwatch s) => s.elapsedMicroseconds / 1000 ~/ 1;

void _report(String what, List<int> samplesMs) {
  final avg = samplesMs.reduce((a, b) => a + b) / samplesMs.length;
  final max = samplesMs.reduce((a, b) => a > b ? a : b);
  final total = samplesMs.reduce((a, b) => a + b);
  // ignore: avoid_print
  print(
    'BENCH $what: first=${samplesMs.first}ms total=${total}ms '
    'avg=${avg.toStringAsFixed(1)}ms max=${max}ms (n=${samplesMs.length})',
  );
}

void _stats(String what) {
  // ignore: avoid_print
  print(
    'BENCH cache $what: hits=${ChapterLineCache.totalHits} '
    'misses=${ChapterLineCache.totalMisses}',
  );
}

void _bench(String line) {
  // ignore: avoid_print
  print('BENCH $line');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Модуль: engbsb (eng-версификация, Пс 119 — 176 стихов), иначе
  // russyn (rsc — Пс 118). Нет ни одного .sb — замер неосуществим.
  final hasBsb = File(_modulePath('engbsb')).existsSync();
  final hasSyn = File(_modulePath('russyn')).existsSync();
  final module = hasBsb ? 'engbsb' : (hasSyn ? 'russyn' : '');
  final chapter = hasBsb ? 119 : 118;
  // testWidgets принимает только bool: причина пропуска — в комментарии
  // (нет каталога данных или в нём нет ни engbsb.sb, ни russyn.sb).
  final skip = module.isEmpty;

  testWidgets('замеры рендер-кэша строк главы (ADR 0030)', (tester) async {
    _bench(
      'mode: render-cache '
      '${kRenderCacheDisabled ? 'OFF (--dart-define=STUDYBIBLE_NO_RENDER_CACHE=true)' : 'ON'}',
    );

    // --- Настройки и предзагрузка модуля: мост идёт в реальном времени ---
    await tester.runAsync(() async {
      await settings.load();
      // «Изучение», слои включены (дефолт), пословная подсветка TTS —
      // ветка voiceWords участвует в сборке строк.
      settings.preview(() {
        settings.readerMode = ReaderMode.study;
        settings.voiceWords = true;
        settings.layerFootnotes = true;
        settings.layerXrefs = true;
        settings.layerStrongs = true;
      });
      await rescanModules();
      final doc = await loadModule(module);
      // Глава заранее — холодная сборка ниже меряет именно рендер,
      // а не мост.
      await doc.ensureChapter('PSA', chapter);
      _bench(
        'module: $module PSA $chapter, versification=${doc.versification}, '
        'verses=${doc.verseCount('PSA', chapter)}',
      );
    });

    // Заглушка-маршрут — монтаж настоящего экрана меряем отдельно.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildThemeData(settings.effectiveTheme),
        home: const SizedBox.shrink(),
      ),
    );

    // Как в main.dart: MaterialApp слушает настройки — каждая
    // нотификация перестраивает тему и весь дом. Виджет экрана
    // создаётся заново, но State (и его кэш строк) живёт.
    Widget harness() => ListenableBuilder(
      listenable: settings,
      builder: (_, _) => MaterialApp(
        theme: buildThemeData(settings.effectiveTheme),
        home: ReadingScreen(
          bookCode: 'PSA',
          chapter: chapter,
          moduleId: module,
        ),
      ),
    );

    final sw = Stopwatch();

    // --- (a) ХОЛОДНАЯ сборка главы: от пустого дерева до строк ---
    await tester.runAsync(() async {
      sw
        ..reset()
        ..start();
      await tester.pumpWidget(harness()); // монтаж; главы ещё нет
      sw.stop();
      // Мост в реальном времени: _load (модуль и глава уже закэшированы)
      // завершается, экран зовёт setState — кадр заказан.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    _bench('mount ReadingScreen (до строк главы): ${sw.elapsedMilliseconds}ms');

    ChapterLineCache.resetTotalStats();
    sw
      ..reset()
      ..start();
    await tester.pump(); // первый кадр со строками главы
    sw.stop();
    _bench(
      'cold chapter build PSA:$chapter (study, from empty): '
      '${sw.elapsedMilliseconds}ms',
    );
    expect(find.textContaining('Глава $chapter'), findsOneWidget);
    _stats('после холодной сборки');

    // Дренаж хвостовых пересборок (префетч сносок, записи пользователя,
    // второй модуль сравнения) — чтобы горячие замеры были чистыми.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // --- (b) ГОРЯЧИЕ пересборки: 20 нотификаций настроек ---
    // xrefScale не входит в сигнатуру рендера — кэш строк остаётся
    // валидным, вся сборка идёт через него (или мимо, при OFF).
    ChapterLineCache.resetTotalStats();
    final hot = <int>[];
    for (var i = 0; i < 20; i++) {
      settings.preview(() => settings.xrefScale = 1.0 + i * 0.01);
      sw
        ..reset()
        ..start();
      await tester.pump();
      sw.stop();
      hot.add(_ms(sw));
    }
    _report('hot rebuild x20 (глава PSA:$chapter, study)', hot);
    _stats('после горячих пересборок (глава)');

    // --- (c) ЛЕНТА КНИГИ: дым + горячие пересборки ---
    // Лента книги работает только вне «Изучения» — на время дыма
    // переключаем и readerMode, в конце возвращаем оба.
    ChapterLineCache.resetTotalStats();
    settings.preview(() {
      settings.readerMode = ReaderMode.reading;
      settings.layoutMode = LayoutMode.book;
    });
    await tester.pump(); // смена сигнатуры рендера — кэш очищен
    // Главы ленты грузятся через мост лениво: реальное время + кадры,
    // пока видимые главы не достроятся.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Глава 1'), findsWidgets);
    final book = <int>[];
    for (var i = 0; i < 20; i++) {
      settings.preview(() => settings.xrefScale = 1.0 + i * 0.01);
      sw
        ..reset()
        ..start();
      await tester.pump();
      sw.stop();
      book.add(_ms(sw));
    }
    _report('hot rebuild x20 (лента книги)', book);
    _stats('после горячих пересборок (лента книги)');

    // Вернуть раскладку (preview ничего не сохраняет).
    settings.preview(() {
      settings.layoutMode = LayoutMode.paragraphs;
      settings.readerMode = ReaderMode.study;
    });
    await tester.pump();
  }, skip: skip);
}
