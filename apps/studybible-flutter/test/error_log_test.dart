/// Журнал ошибок (BUGS 18.10.2026, «молчаливые ошибки»):
/// кольцевой буфер при переполнении держит самые свежие 200 записей,
/// записи сохраняют контекст/ошибку/стек, очистка работает.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/error_log.dart';

void main() {
  test('переполнение: остаются самые свежие 200 записей', () {
    final log = ErrorLog();
    for (var i = 0; i < 250; i++) {
      log.logError('ctx', StateError('e$i'));
    }
    expect(log.count, ErrorLog.maxRecords);
    final recs = log.records;
    // Первые 50 вытеснены: старейшая сохранившаяся — e50.
    expect((recs.first.error as StateError).message, 'e50');
    expect((recs.last.error as StateError).message, 'e249');
  });

  test('запись сохраняет контекст, ошибку и стек', () {
    final log = ErrorLog();
    final st = StackTrace.current;
    log.logError('settings.load', const FormatException('битый JSON'), st);
    final r = log.records.single;
    expect(r.context, 'settings.load');
    expect(r.error, isA<FormatException>());
    expect((r.error as FormatException).message, 'битый JSON');
    expect(r.stack, same(st));
    // Время записи — не позже текущего (могут совпасть в ту же мс).
    expect(r.time.isAfter(DateTime.now()), isFalse);
  });

  test('стек не обязателен', () {
    final log = ErrorLog();
    log.logError('module.load', 'текст вместо объекта');
    final r = log.records.single;
    expect(r.stack, isNull);
    expect(r.error, 'текст вместо объекта');
  });

  test('очистка опустошает журнал', () {
    final log = ErrorLog();
    log.logError('settings.save', StateError('а'));
    log.logError('settings.save', StateError('б'));
    expect(log.count, 2);
    log.clear();
    expect(log.count, 0);
    expect(log.records, isEmpty);
    // После очистки журнал снова пишется.
    log.logError('modules.rescan', StateError('в'));
    expect(log.count, 1);
  });

  test('records — неизменяемая копия', () {
    final log = ErrorLog();
    log.logError('a', 1);
    final recs = log.records;
    expect(
      () =>
          recs.add((time: DateTime.now(), context: 'x', error: 2, stack: null)),
      throwsUnsupportedError,
    );
    // Новые записи не попадают в ранее выданную копию.
    log.logError('b', 2);
    expect(recs.length, 1);
    expect(log.count, 2);
  });
}
