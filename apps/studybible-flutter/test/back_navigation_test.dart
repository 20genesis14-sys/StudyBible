/// Регрессия навигации «назад» (ROADMAP 1.1.2):
/// - стрелка шапки читалки — `_hierarchyBack()`: строго вверх
///   по иерархии (глава → сетка глав книги) через `_popRoute()`
///   мимо перехвата PopScope;
/// - системный «назад» — `_stackBack()` через PopScope: шаг по
///   стеку позиций workspace, а pop маршрута — только когда
///   стек исчерпан.
///
/// Запуск: STUDYBIBLE_DATA=~/StudyBible-data flutter test
/// test/back_navigation_test.dart — читалке нужен настоящий
/// russyn.sb, без каталога данных тесты пропускаются.
///
/// Реальные вызовы моста (модуль, настройки) идут через
/// `tester.runAsync` — в зоне FakeAsync они не выполняются.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/data.dart';
import 'package:studybible/routes.dart';
import 'package:studybible/screens/chapter_grid_screen.dart';
import 'package:studybible/screens/reading_screen.dart';
import 'package:studybible/state.dart';
import 'package:studybible/theme.dart';
import 'package:studybible/workspace/reader_workspace.dart';

bool _hasSb() {
  final dir = Platform.environment['STUDYBIBLE_DATA'];
  if (dir == null) return false;
  return File(
    '$dir${Platform.pathSeparator}modules${Platform.pathSeparator}russyn.sb',
  ).existsSync();
}

/// Настройки + скан модулей + дерево: сетка GEN → читалка GEN 1
/// (openedFromGrid). Возвращается после реальной загрузки главы.
Future<void> _bootWithReader(WidgetTester tester) async {
  await tester.runAsync(() async {
    await settings.load();
    await rescanModules();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildThemeData(AppTheme.light),
        home: const ChapterGridScreen(bookCode: 'GEN'),
      ),
    );
    await Future.delayed(const Duration(milliseconds: 300));
    Navigator.of(tester.element(find.byType(ChapterGridScreen))).push(
      fastRoute(
        const ReadingScreen(
          bookCode: 'GEN',
          chapter: 1,
          openedFromGrid: true,
          moduleId: 'russyn',
        ),
      ),
    );
    // Глава грузится через мост — ждём реального времени.
    await Future.delayed(const Duration(seconds: 2));
  });
  // Маршрут поднят в реальном времени — догоняем кадрами fake-time.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hasSb = _hasSb();

  testWidgets('стрелка шапки ведёт на сетку глав текущей книги', (
    tester,
  ) async {
    await _bootWithReader(tester);
    expect(find.byType(ReadingScreen), findsOneWidget);

    // Тап стрелки шапки — pop на ту же сетку (openedFromGrid и та
    // же книга). Не pushReplacement и не «по стеку».
    await tester.tap(find.byIcon(Icons.arrow_back));
    // _popRoute действует на следующем кадре; анимация pop — в
    // реальном времени, так что ждём её тоже в runAsync.
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ChapterGridScreen), findsOneWidget);
    expect(find.byType(ReadingScreen), findsNothing);
  }, skip: !hasSb);

  testWidgets('системный «назад» — шаг по стеку, потом выход', (tester) async {
    await _bootWithReader(tester);
    expect(find.byType(ReadingScreen), findsOneWidget);

    // Внутренний переход: вторая позиция в стеке workspace
    // (как тап по ссылке сноски — новая позиция, тот же маршрут).
    workspace.go(
      const Location.verse(moduleId: 'russyn', book: 'GEN', chapter: 2),
    );

    // Системный «назад» — шаг по стеку на первую позицию,
    // маршрут НЕ снимается. pageBack() не годится: он ищет
    // кнопку навбара, а не шлёт системный pop.
    await tester.binding.handlePopRoute();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(
      find.byType(ReadingScreen),
      findsOneWidget,
      reason: 'стек не пуст — «назад» шагает по позициям, не выход',
    );
    expect(workspace.current?.chapter, 1);

    // Стек исчерпан — следующий «назад» отпускает pop на сетку.
    await tester.binding.handlePopRoute();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ChapterGridScreen), findsOneWidget);
    expect(find.byType(ReadingScreen), findsNothing);
  }, skip: !hasSb);
}
