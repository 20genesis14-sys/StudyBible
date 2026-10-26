import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/reader/line_cache.dart';

/// Распознаватель с меткой утилизации — проверяет жизненный цикл
/// владельца (ADR 0030).
class TrackingRecognizer extends TapGestureRecognizer {
  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

Widget _probe() => const SizedBox(width: 1, height: 1);

void main() {
  testWidgets('put/get: запись живёт, распознаватели целы', (tester) async {
    final cache = ChapterLineCache();
    final rec = TrackingRecognizer();
    cache.put('L:1', _probe(), [rec]);
    expect(cache.get('L:1'), isNotNull);
    expect(rec.disposed, isFalse);
    cache.dispose();
  });

  testWidgets('evict: dispose распознавателей — после кадра', (tester) async {
    final cache = ChapterLineCache();
    final rec = TrackingRecognizer();
    cache.put('L:1', _probe(), [rec]);
    cache.evict('L:1');
    expect(cache.get('L:1'), isNull);
    // До конца кадра распознаватель жив (виджет мог быть в прошлом
    // кадре), после пост-кадрового колбэка — утилизирован.
    expect(rec.disposed, isFalse);
    // Пост-кадровый колбэк сам кадр не заказывает — заказываем явно.
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(rec.disposed, isTrue);
    cache.dispose();
  });

  testWidgets('put поверх ключа: прежняя запись выселяется', (tester) async {
    final cache = ChapterLineCache();
    final old = TrackingRecognizer();
    final fresh = TrackingRecognizer();
    cache.put('B:0', _probe(), [old]);
    cache.put('B:0', _probe(), [fresh]);
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(old.disposed, isTrue);
    expect(fresh.disposed, isFalse);
    cache.dispose();
    expect(fresh.disposed, isTrue);
  });

  testWidgets('clear: все записи выселены, dispose после кадра',
      (tester) async {
    final cache = ChapterLineCache();
    final a = TrackingRecognizer();
    final b = TrackingRecognizer();
    cache.put('L:1', _probe(), [a]);
    cache.put('L:2', _probe(), [b]);
    expect(cache.length, 2);
    cache.clear();
    expect(cache.length, 0);
    expect(a.disposed, isFalse);
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(a.disposed, isTrue);
    expect(b.disposed, isTrue);
    cache.dispose();
  });

  test('dispose: утилизация немедленно, без кадра', () {
    final cache = ChapterLineCache();
    final rec = TrackingRecognizer();
    cache.put('L:1', _probe(), [rec]);
    cache.dispose();
    expect(rec.disposed, isTrue);
  });

  test('распознаватель кэша остаётся GestureRecognizer', () {
    // Страховка: TrackingRecognizer остаётся TapGestureRecognizer'ом,
    // список типов в кэше не сужается.
    final GestureRecognizer rec = TrackingRecognizer();
    expect(rec, isA<TapGestureRecognizer>());
    rec.dispose();
  });
}
