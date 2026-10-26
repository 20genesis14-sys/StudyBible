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

  group('findRefs: OSIS-аббревиатуры (слой параллельных, ADR 0023)', () {
    test('короткие OSIS-имена разбираются', () {
      final samples = {
        'Gen 1:1': 'GEN',
        'Ps 104:30': 'PSA',
        'Isa 40:28': 'ISA',
        'Matt 5:3': 'MAT',
        'John 3:16': 'JHN',
        'Rev 22:21': 'REV',
        '1Sam 22:1': '1SA',
        '1Kgs 17:1': '1KI',
        'Song 1:1': 'SNG',
        'Phlm 1:5': 'PHM',
        'Jude 1:6': 'JUD',
      };
      for (final e in samples.entries) {
        expect(findRefs(e.key).single.ref.book, e.value, reason: e.key);
      }
    });

    test('диапазон и список как в тексте слоя', () {
      const t = 'Ps 104:30; Ps 139:13-16; Isa 40:28 – Jer 1:5';
      final m = findRefs(t);
      expect(m, hasLength(4));
      expect(m.map((e) => e.ref.book).toList(), [
        'PSA',
        'PSA',
        'ISA',
        'JER',
      ]);
      expect(m[1].ref.verseEnd, 16);
    });

    test('полные английские имена не перекрываются OSIS', () {
      // Частые слова совпадают с OSIS-кодами — полное имя сильнее.
      expect(findRefs('Acts 2:38').single.ref.book, 'ACT');
      expect(findRefs('Job 1:1').single.ref.book, 'JOB');
      expect(findRefs('Jude 1:1').single.ref.book, 'JUD');
    });
  });

  group('localizeRefs: имена книг по локали', () {
    final ru = {'LEV': 'Лев', 'NUM': 'Чис', 'DEU': 'Втор', 'GEN': 'Быт'};

    test('OSIS-имена заменяются локальными', () {
      expect(
        localizeRefs('Lev 23:10; Num 15:18', (c) => ru[c] ?? c),
        'Лев 23:10; Чис 15:18',
      );
    });

    test('диапазоны и разделители сохраняются', () {
      expect(
        localizeRefs('Gen 4:25 – Gen 5:32; Lev 1:1-17', (c) => ru[c] ?? c),
        'Быт 4:25 – Быт 5:32; Лев 1:1-17',
      );
    });

    test('текст без ссылок не меняется', () {
      const t = 'просто текст без ссылок';
      expect(localizeRefs(t, (c) => c), t);
    });

    test('результат снова разбирается findRefs', () {
      final t = localizeRefs('Lev 23:10; Num 15:18', (c) => ru[c] ?? c);
      expect(findRefs(t).map((m) => m.ref.book).toList(), ['LEV', 'NUM']);
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

  group('parseQueryRef: омнибокс поиска', () {
    test('распознаёт стих, главу без стиха и нижний регистр', () {
      final r1 = parseQueryRef('Ин 3:16')!;
      expect((r1.book, r1.chapter, r1.verse), ('JHN', 3, 16));

      final r2 = parseQueryRef('быт 1')!;
      expect((r2.book, r2.chapter, r2.verse), ('GEN', 1, 1));

      final r3 = parseQueryRef('1кор 13:4-7')!;
      expect((r3.book, r3.chapter, r3.verse, r3.verseEnd), ('1CO', 13, 4, 7));

      final r4 = parseQueryRef('john 3 16')!;
      expect((r4.book, r4.chapter, r4.verse), ('JHN', 3, 16));

      expect(parseQueryRef('просто текст запроса'), isNull);
    });
  });
}
