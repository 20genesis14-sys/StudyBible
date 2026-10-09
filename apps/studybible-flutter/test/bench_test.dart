/// Замеры времён (открытые вопросы № 11, № 22): холодный путь
/// загрузки модуля, открытие главы, поиск. Не тест-критерий —
/// измеритель; цифры печатаются в вывод.
///
/// Запуск:
///   STUDYBIBLE_DATA=~/StudyBible-data flutter test test/bench_test.dart
///
/// Без каталога данных замеры пропускаются.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/data.dart';
import 'package:studybible/native_bridge.dart' show SearchHit;
import 'package:studybible/native_bridge_io.dart';

String get _dataDir => Platform.environment['STUDYBIBLE_DATA'] ?? '';

String _modulePath(String id) =>
    '$_dataDir${Platform.pathSeparator}modules${Platform.pathSeparator}$id.sb';

int _ms(Stopwatch s) => s.elapsedMicroseconds / 1000 ~/ 1;

void _report(String what, List<int> samplesMs) {
  final avg = samplesMs.reduce((a, b) => a + b) / samplesMs.length;
  final max = samplesMs.reduce((a, b) => a > b ? a : b);
  // ignore: avoid_print
  print(
    'BENCH $what: first=${samplesMs.first}ms '
    'avg=${avg.toStringAsFixed(1)}ms max=${max}ms (n=${samplesMs.length})',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hasSb = _dataDir.isNotEmpty &&
      File('${_modulePath('russyn')}').existsSync();

  test('замеры: модуль / глава / поиск (№ 11, № 22)', () async {
    // --- Холодный путь: сначала изолированный init моста ---
    var s = Stopwatch()..start();
    await bridgeEntriesList('mark');
    s.stop();
    print('BENCH bridge-init (первый вызов моста): ${s.elapsedMilliseconds}ms');

    s = Stopwatch()..start();
    final syn = await loadModule('russyn');
    s.stop();
    print('BENCH module-open russyn (каталог+схема): ${s.elapsedMilliseconds}ms');

    // --- Открытие главы: несколько книг, включая самую длинную ---
    // PSA 119 — 176 стихов; GEN 1 — короткая; ISA 53 — средняя.
    for (final (code, ch) in [('GEN', 1), ('ISA', 53), ('PSA', 119)]) {
      // первая загрузка — холодная, остальные — тёплый кэш sqlite.
      await syn.ensureChapter(code, ch); // прогрев кэша страниц
      final t = <int>[];
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        // заново читаем через мост, минуя кэш ModuleDoc:
        final raw = await bridgeChapterDoc(_modulePath('russyn'), code, ch);
        sw.stop();
        expect(raw, isNotNull);
        t.add(_ms(sw));
      }
      _report('chapter $code:$ch (russyn)', t);
    }

    // --- Большой модуль: engwebp (Стронг + привязки) ---
    if (File(_modulePath('engwebp')).existsSync()) {
      s = Stopwatch()..start();
      final nwt = await loadModule('engwebp');
      print('BENCH module-open engwebp: ${s.elapsedMilliseconds}ms');
      await nwt.ensureChapter('PSA', 119);
      final t = <int>[];
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        await bridgeChapterDoc(_modulePath('engwebp'), 'PSA', 119);
        sw.stop();
        t.add(_ms(sw));
      }
      _report('chapter PSA:119 (engwebp, большой)', t);
    }

    // --- Комментарии (comm-henry) как «тяжёлый» документ ---
    if (File(_modulePath('comm-henry')).existsSync()) {
      s = Stopwatch()..start();
      await loadModule('comm-henry');
      print('BENCH module-open comm-henry: ${s.elapsedMilliseconds}ms');
    }

    // --- Поиск: одиночное слово и фраза ---
    for (final q in ['любовь', 'в начале сотворил', 'Иегова']) {
      final t = <int>[];
      List<SearchHit> hits = const [];
      for (var i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        hits = await bridgeModuleSearch(_modulePath('russyn'), q, limit: 100);
        sw.stop();
        t.add(_ms(sw));
      }
      _report('search "$q" (${hits.length} hits)', t);
    }
  }, skip: hasSb ? false : 'нет STUDYBIBLE_DATA');
}
