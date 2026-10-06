import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/refs.dart';

void main() {
  group('findRefs: русские названия', () {
    test('полное имя и сокращения', () {
      for (final s in [
        'Быт 1:1',
        'Бытие 1:1',
        'Пс 22:1',
        'Псалом 22:1',
        'Прит 3:5',
        'Ин 3:16',
        'Иоан 3:16',
        'Откр 22:21',
        'Деян 2:38',
      ]) {
        final m = findRefs(s);
        expect(m, hasLength(1), reason: s);
      }
      expect(findRefs('Быт 1:1').single.ref.book, 'GEN');
      expect(findRefs('Ин 3:16').single.ref.book, 'JHN');
      expect(findRefs('Откр 22:21').single.ref.book, 'REV');
    });

    test('книги с номером', () {
      expect(findRefs('1 Кор 15:45').single.ref.book, '1CO');
      expect(findRefs('2 Кор 4:6').single.ref.book, '2CO');
      expect(findRefs('1 Пет 1:3').single.ref.book, '1PE');
      expect(findRefs('3 Цар 17:1').single.ref.book, '1KI');
      expect(findRefs('2 Пар 7:14').single.ref.book, '2CH');
      expect(findRefs('1 Ин 1:9').single.ref.book, '1JN');
    });

    test('глава и стих разбираются', () {
      final r = findRefs('Иер 29:11').single.ref;
      expect((r.book, r.chapter, r.verse), ('JER', 29, 11));
    });

    test('диапазон стихов берёт начало', () {
      final r = findRefs('Мф 5:3-11').single.ref;
      expect((r.book, r.chapter, r.verse), ('MAT', 5, 3));
    });

    test('запятая вместо двоеточия', () {
      expect(findRefs('Быт 1,1'), hasLength(1));
    });

    test('несколько ссылок в одном тексте, позиции сохраняются', () {
      const t = 'Ср. Исх 20:11 и Пс 33:6; также Ин 1:3.';
      final m = findRefs(t);
      expect(m, hasLength(3));
      expect(m.map((e) => e.ref.book).toList(), ['EXO', 'PSA', 'JHN']);
      expect(
        t.substring(m[1].start, m[1].end),
        contains('33:6'),
      );
    });
  });

  group('findRefs: английские названия', () {
    test('WEB/KJV-стиль', () {
      expect(findRefs('Genesis 1:1').single.ref.book, 'GEN');
      expect(findRefs('Exodus 3:3-4').single.ref.book, 'EXO');
      expect(findRefs('Psalm 23:1').single.ref.book, 'PSA');
      expect(findRefs('1 Corinthians 13:4').single.ref.book, '1CO');
      expect(findRefs('Revelation 22:21').single.ref.book, 'REV');
    });
  });

  group('findRefs: отказ в непонятном', () {
    test('не книга — не ссылка', () {
      expect(findRefs('см. раздел 3:5 далее'), isEmpty);
      expect(findRefs('стих 3:16 без книги рядом'), isEmpty);
      expect(findRefs(''), isEmpty);
      expect(findRefs('Быт'), isEmpty);
      expect(findRefs('Быт 1'), isEmpty);
    });

    test('нулевые номера отбрасываются', () {
      expect(findRefs('Быт 0:1'), isEmpty);
      expect(findRefs('Быт 1:0'), isEmpty);
    });
  });
}
