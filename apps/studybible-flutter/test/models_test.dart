import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/models.dart';

Map<String, dynamic> chapterJson() => {
  'n': 1,
  'blocks': [
    {
      'k': 'd',
      'm': 'd',
      's': [
        {'t': 'Надписание до первого стиха', 's': '', 'a': ''},
      ],
    },
    {
      'k': 'p',
      'm': 'p',
      's': [
        {'v': 1},
        {'t': 'В начале сотворил Бог ', 's': '', 'a': 'strong="H7225"'},
        {'t': 'небо и землю.', 's': '', 'a': ''},
        {'n': 'f', 'c': 'a', 't': 'Сноска: Быт 1:1'},
        {'v': 2},
        {'t': 'Земля была безвидна.', 's': '', 'a': ''},
      ],
    },
    {
      'k': 'q',
      'm': 'q1',
      's': [
        {'v': 3},
        {'t': 'И сказал Бог: да будет свет.', 's': 'wj', 'a': ''},
      ],
    },
    {'k': 'b', 'm': 'b', 's': []},
    {
      'k': 'x',
      'm': '?',
      's': [],
    },
  ],
};

Map<String, dynamic> moduleJson() => {
  'id': 'testmod',
  'title': 'Тестовый модуль',
  'language': 'ru',
  'books': [
    {'code': 'GEN', 'title': 'Бытие', 'chapters': 50},
    {'code': 'EXO', 'title': 'Исход', 'chapters': 40},
  ],
  'chapters': {'GEN:1': chapterJson()},
  'verse_counts': {'GEN:1': 3, 'GEN:2': 25},
};

void main() {
  group('ModuleDoc.fromJson', () {
    test('книги, главы, verseCounts', () {
      final m = ModuleDoc.fromJson(moduleJson());
      expect(m.id, 'testmod');
      expect(m.books, hasLength(2));
      expect(m.bookByCode('EXO')!.title, 'Исход');
      expect(m.bookByCode('XXX'), isNull);
      expect(m.chapter('GEN', 1), isNotNull);
      expect(m.chapter('GEN', 2), isNull);
      expect(m.verseCount('GEN', 1), 3);
      expect(m.verseCount('GEN', 2), 25);
      expect(m.verseCount('GEN', 99), 0);
    });

    test('verse_counts отсутствует — пустая карта', () {
      final j = moduleJson()..remove('verse_counts');
      expect(ModuleDoc.fromJson(j).verseCounts, isEmpty);
    });
  });

  group('BlockDoc/SpanDoc', () {
    test('типы блоков: p q h d b и неизвестный → paragraph', () {
      final ch = ModuleDoc.fromJson(moduleJson()).chapter('GEN', 1)!;
      expect(ch.blocks[0].kind, BlockKind.superscription);
      expect(ch.blocks[1].kind, BlockKind.paragraph);
      expect(ch.blocks[2].kind, BlockKind.poetry);
      expect(ch.blocks[3].kind, BlockKind.blank);
      expect(ch.blocks[4].kind, BlockKind.paragraph); // 'x' неизвестен
    });

    test('спаны: стих, текст со стилем/атрибутами, сноска', () {
      final spans = ModuleDoc.fromJson(moduleJson()).chapter('GEN', 1)!.blocks[1].spans;
      expect(spans[0], isA<VerseSpanDoc>());
      expect((spans[0] as VerseSpanDoc).verse, 1);
      final t = spans[1] as TextSpanDoc;
      expect(t.strong, 'H7225');
      final note = spans[3] as NoteSpanDoc;
      expect(note.kind, 'f');
      expect(note.caller, 'a');
      expect(note.text, contains('Быт 1:1'));
      // wj-стиль сохраняется
      final q = ModuleDoc.fromJson(moduleJson()).chapter('GEN', 1)!.blocks[2].spans;
      expect((q[1] as TextSpanDoc).style, 'wj');
    });

    test('strong: G-номера, отсутствие атрибута', () {
      TextSpanDoc s(String a) => TextSpanDoc(text: 'x', style: '', attrs: a);
      expect(s('strong="G25"').strong, 'G25');
      expect(s('').strong, isNull);
      expect(s('lemma="x"').strong, isNull);
      expect(s('strong="H1" strong="H2"').strong, 'H1'); // первый
    });
  });

  group('verseText', () {
    late ChapterDoc ch;
    setUp(() {
      ch = ModuleDoc.fromJson(moduleJson()).chapter('GEN', 1)!;
    });

    test('один стих — только его текст, без сносок и номеров', () {
      expect(verseText(ch, 1), 'В начале сотворил Бог небо и землю.');
      expect(verseText(ch, 2), 'Земля была безвидна.');
    });

    test('диапазон стихов склеивается пробелом', () {
      expect(
        verseText(ch, 1, 2),
        'В начале сотворил Бог небо и землю. Земля была безвидна.',
      );
    });

    test('текст до первого стиха и после диапазона не попадает', () {
      expect(verseText(ch, 1), isNot(contains('Надписание')));
      expect(verseText(ch, 1), isNot(contains('свет')));
    });

    test('несуществующий стих → пустая строка', () {
      expect(verseText(ch, 99), '');
    });
  });

  group('ensureChapter: ленивая загрузка', () {
    test('уже загруженная глава — без вызова лоадера', () async {
      var calls = 0;
      final m = ModuleDoc.fromJson(moduleJson());
      final lazy = ModuleDoc(
        id: m.id,
        title: m.title,
        language: m.language,
        books: m.books,
        chapters: m.chapters,
        verseCounts: m.verseCounts,
        chapterLoader: (c, n) async {
          calls++;
          return null;
        },
      );
      expect((await lazy.ensureChapter('GEN', 1))!.number, 1);
      expect(calls, 0);
    });

    test('один параллельный запрос на главу — лоадер зовётся один раз', () async {
      var calls = 0;
      final m0 = ModuleDoc.fromJson(moduleJson());
      final m = ModuleDoc(
        id: m0.id,
        title: m0.title,
        language: m0.language,
        books: m0.books,
        chapters: {},
        verseCounts: m0.verseCounts,
        chapterLoader: (c, n) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return jsonEncode(chapterJson());
        },
      );
      final r = await Future.wait([
        m.ensureChapter('GEN', 5),
        m.ensureChapter('GEN', 5),
      ]);
      expect(calls, 1);
      expect(r[0]!.number, 1);
      // повтор — из кэша
      await m.ensureChapter('GEN', 5);
      expect(calls, 1);
    });

    test('без лоадера — null; лоадер вернул null — null без кэша', () async {
      final m0 = ModuleDoc.fromJson(moduleJson());
      expect(await m0.ensureChapter('GEN', 5), isNull);
      var calls = 0;
      final m = ModuleDoc(
        id: 'm',
        title: 'm',
        language: '',
        books: const [],
        chapters: {},
        verseCounts: const {},
        chapterLoader: (c, n) async {
          calls++;
          return null;
        },
      );
      expect(await m.ensureChapter('GEN', 5), isNull);
      expect(await m.ensureChapter('GEN', 5), isNull);
      expect(calls, 2);
    });
  });
}
