/// Режим «две панели» (B10 этап 2, ROADMAP E1):
/// - широкий экран (≥700): кнопка «Две панели» разворачивает вторую
///   панель чтения и возвращает одну;
/// - взаимная синхронизация: переход активной панели ведёт связанную
///   за ней (та же книга/глава, тот же модуль);
/// - отвязанная панель (кнопка связи в шапке колонки) за навигацией
///   не ходит;
/// - тап в панели переводит фокус: клавиши ←/→ листают её;
/// - пресет «Сравнение» (лист «Раскладка») открывает две связанные
///   панели;
/// - смена раскладки пишет Settings.workspaceJson (отложенная запись);
/// - восстановление: снимок из workspaceJson открывает две панели
///   на сохранённых позициях;
/// - узкий экран (600): кнопок раскладки в шапке нет, панель одна.
///
/// Запуск: STUDYBIBLE_DATA=~/StudyBible-data flutter test
/// test/split_panes_test.dart — читалке нужен настоящий russyn.sb,
/// без каталога данных тесты пропускаются.
///
/// Реальные вызовы моста (модуль, конверсия) идут через
/// `tester.runAsync` — в зоне FakeAsync они не выполняются.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/data.dart';
import 'package:studybible/native_bridge_io.dart';
import 'package:studybible/reader/page_swipe.dart';
import 'package:studybible/screens/reading_screen.dart';
import 'package:studybible/state.dart';
import 'package:studybible/theme.dart';
import 'package:studybible/workspace/workspace_model.dart';

bool _hasSb() {
  final dir = Platform.environment['STUDYBIBLE_DATA'];
  if (dir == null) return false;
  return File(
    '$dir${Platform.pathSeparator}modules${Platform.pathSeparator}russyn.sb',
  ).existsSync();
}

/// Настройки + скан модулей + читалка GEN 1 в окне [size]
/// (логические пиксели). Возвращается после реальной загрузки главы.
Future<void> _bootReader(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.runAsync(() async {
    await settings.load();
    await rescanModules();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildThemeData(AppTheme.light),
        home: const ReadingScreen(
          bookCode: 'GEN',
          chapter: 1,
          moduleId: 'russyn',
        ),
      ),
    );
    // Глава грузится через мост — ждём реального времени.
    await Future.delayed(const Duration(milliseconds: 1500));
  });
  // Маршрут поднят в реальном времени — догоняем кадрами fake-time.
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Догнать асинхронные загрузки (мост) и кадры пересборки.
Future<void> _settle(WidgetTester tester, [int ms = 700]) async {
  await tester.runAsync(() => Future.delayed(Duration(milliseconds: ms)));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Тела чтения: byType не годится — в приложении тип параметризован
/// (ReaderPageSwipe<(String, int, String?)>), сравнение runtimeType
/// строгое.
Finder _bodies() => find.byWidgetPredicate((w) => w is ReaderPageSwipe);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hasSb = _hasSb();

  // Раскладка не должна перетекать между тестами: temp-база настроек
  // общая, снимок рабочего места пишется отложенно (800 мс).
  tearDown(() async {
    if (settings.workspaceJson == null) return;
    settings.update(() => settings.workspaceJson = null);
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final raw = await bridgeSettingsLoad();
      // Снимок лежит в блобе настроек экранированной строкой:
      // "workspace":"{\"version\":1,...".
      if (raw == null || !raw.contains('"workspace":"{')) break;
    }
  });

  testWidgets('широкий экран: включение — две панели, выключение — одна', (
    tester,
  ) async {
    await _bootReader(tester, const Size(1400, 1000));
    expect(_bodies(), findsOneWidget);
    expect(find.text('Глава 1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.splitscreen));
    await tester.pump();
    await _settle(tester);
    // Вторая панель стартует с позиции первой.
    expect(_bodies(), findsNWidgets(2));
    expect(find.text('Глава 1'), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.splitscreen));
    await tester.pump();
    await _settle(tester, 300);
    expect(_bodies(), findsOneWidget);
    expect(find.text('Глава 1'), findsOneWidget);
  }, skip: !hasSb);

  testWidgets('взаимная синхронизация: GEN 3 в активной — вторая следует', (
    tester,
  ) async {
    await _bootReader(tester, const Size(1400, 1000));
    await tester.tap(find.byIcon(Icons.splitscreen));
    await tester.pump();
    await _settle(tester);

    // Стрелки листают активную (первую) панель: GEN 1 → 2 → 3;
    // связанная панель ходит за ней.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settle(tester);
    expect(find.text('Глава 2'), findsNWidgets(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settle(tester);
    expect(find.text('Глава 3'), findsNWidgets(2));
  }, skip: !hasSb);

  testWidgets('отвязанная панель за навигацией не следует', (tester) async {
    await _bootReader(tester, const Size(1400, 1000));
    await tester.tap(find.byIcon(Icons.splitscreen));
    await tester.pump();
    await _settle(tester);
    // Кнопка связи в шапке второй панели — отвязать (обе привязаны,
    // вторая по порядку — последняя).
    await tester.tap(find.byIcon(Icons.link).last);
    await tester.pump();
    await _settle(tester, 200);
    expect(find.byIcon(Icons.link_off), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settle(tester);
    expect(find.text('Глава 2'), findsOneWidget);
    expect(find.text('Глава 1'), findsOneWidget);
  }, skip: !hasSb);

  testWidgets('тап по панели переводит фокус: клавиши листают её', (
    tester,
  ) async {
    await _bootReader(tester, const Size(1400, 1000));
    await tester.tap(find.byIcon(Icons.splitscreen));
    await tester.pump();
    await _settle(tester);
    // Отвязать вторую панель кнопкой в её шапке.
    await tester.tap(find.byIcon(Icons.link).last);
    await tester.pump();
    await _settle(tester, 200);

    // Тап по тексту второй панели (середина правой половины) — фокус
    // переходит на неё; стрелка листает теперь её, первая на месте.
    await tester.tapAt(const Offset(1050, 500));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settle(tester);
    expect(find.text('Глава 2'), findsOneWidget);
    expect(find.text('Глава 1'), findsOneWidget);
  }, skip: !hasSb);

  testWidgets('пресет «Сравнение»: две панели, обе связаны', (tester) async {
    await _bootReader(tester, const Size(1400, 1000));
    // Кнопка «Раскладка» верхней панели → лист пресетов.
    await tester.tap(find.byIcon(Icons.dashboard_customize));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Сравнение'));
    await tester.pump();
    await _settle(tester);

    // Две панели, обе привязаны: в обеих шапках кнопка link.
    expect(_bodies(), findsNWidgets(2));
    expect(find.byIcon(Icons.link), findsNWidgets(2));

    // Связанные панели ходят за навигацией активной.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settle(tester);
    expect(find.text('Глава 2'), findsNWidgets(2));
  }, skip: !hasSb);

  testWidgets('узкий экран: кнопки раскладки нет, пункт есть в «Слоях»', (
    tester,
  ) async {
    await _bootReader(tester, const Size(600, 1000));
    expect(_bodies(), findsOneWidget);
    expect(find.byIcon(Icons.dashboard_customize), findsNothing);

    // Кнопка «Слои» нижней панели — лист с пунктом «Раскладка».
    await tester.tap(find.text('Слои'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Раскладка'), findsOneWidget);

    // Пункт открывает лист пресетов; закрываем тапом мимо листа.
    await tester.tap(find.text('Раскладка'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Сравнение'), findsOneWidget);
    await tester.tapAt(const Offset(300, 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_bodies(), findsOneWidget);
    await _settle(tester);
  }, skip: !hasSb);

  testWidgets('смена раскладки пишет workspaceJson (отложенная запись)', (
    tester,
  ) async {
    await _bootReader(tester, const Size(1400, 1000));
    // Начисто: запись от старых прогонов не должна путать.
    settings.update(() => settings.workspaceJson = null);

    await tester.tap(find.byIcon(Icons.splitscreen));
    await tester.pump();
    // Дебаунс записи — 800 мс: дотягиваем fake-время до срабатывания.
    await tester.pump(const Duration(milliseconds: 900));

    expect(settings.workspaceJson, isNotNull);
    final ws = decodeWorkspace(settings.workspaceJson!);
    expect(ws, isNotNull);
    expect(ws!.panes.length, 2);
    expect(ws.layout.type, WorkspaceLayoutType.splitHorizontal);
    expect(ws.panes.every((p) => p.source == 'russyn'), isTrue);
    expect(ws.panes.first.linkGroup, 'main');
    await _settle(tester);
  }, skip: !hasSb);

  testWidgets('восстановление: две панели из сохранённого снимка', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final saved = WorkspaceConfig(
      layout: const WorkspaceLayoutSpec.splitHorizontal(ratio: 0.6),
      activePane: 0,
      panes: [
        PaneConfig(
          id: 'reader',
          type: PaneType.reader,
          source: 'russyn',
          linkGroup: 'main',
          book: 'GEN',
          chapter: 1,
        ),
        PaneConfig(
          id: 'pane-1',
          type: PaneType.reader,
          source: 'russyn',
          book: 'GEN',
          chapter: 2,
        ),
      ],
    );
    await tester.runAsync(() async {
      await settings.load();
      await rescanModules();
      settings.update(() => settings.workspaceJson = encodeWorkspace(saved));
      // Дождаться записи в temp-базу: settings.load() читалки берёт
      // снимок оттуда же, откуда его видит следующий запуск. Снимок
      // лежит в блобе экранированной строкой.
      var written = false;
      for (var i = 0; i < 100 && !written; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        written =
            (await bridgeSettingsLoad())?.contains('"workspace":"{') ?? false;
      }
      expect(written, isTrue, reason: 'workspace не записался в UserData');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildThemeData(AppTheme.light),
          home: const ReadingScreen(
            bookCode: 'GEN',
            chapter: 1,
            moduleId: 'russyn',
          ),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 1500));
    });
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Две панели на сохранённых позициях: GEN 1 и GEN 2 — хотя
    // читалку открыли с аргументами GEN 1.
    expect(_bodies(), findsNWidgets(2));
    expect(find.text('Глава 1'), findsOneWidget);
    expect(find.text('Глава 2'), findsOneWidget);
  }, skip: !hasSb);
}
