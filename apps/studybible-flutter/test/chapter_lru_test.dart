import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/models.dart';

/// JSON главы [n] — минимальный: один абзац, один стих.
Map<String, dynamic> chapterJson(int n) => {
  'n': n,
  'blocks': [
    {
      'k': 'p',
      'm': 'p',
      's': [
        {'v': 1},
        {'t': 'Глава $n', 's': '', 'a': ''},
      ],
    },
  ],
};

/// Ленивый модуль с фейковым JSON-лоадером (B9: LRU глав).
ModuleDoc lazyModule({
  required Future<String?> Function(String code, int n) loader,
}) => ModuleDoc(
  id: 'lazy',
  title: 'Ленивый',
  language: 'ru',
  books: [BookDoc(code: 'GEN', title: 'Бытие', chapters: 1000)],
  chapters: {},
  verseCounts: const {},
  chapterLoader: loader,
);

void main() {
  group('LRU глав ленивого модуля (B9, DECISIONS 18.10.2026)', () {
    test('сверх потолка — свежая на месте, старейшая вытеснена', () async {
      final cap = ModuleDoc.kChapterLruCap;
      final m = lazyModule(loader: (c, n) async => jsonEncode(chapterJson(n)));
      for (var i = 1; i <= cap + 38; i++) {
        await m.ensureChapter('GEN', i);
      }
      expect(m.chapters.length, cap);
      expect(m.chapter('GEN', cap + 38), isNotNull);
      expect(m.chapter('GEN', 1), isNull);
    });

    test('прикосновение к ранней главе спасает её от вытеснения', () async {
      final cap = ModuleDoc.kChapterLruCap;
      const early = 60; // вытесняется при переполнении без прикосновений
      const evicted = 39; // старейшая после наполнения
      var evictedCalls = 0;
      final m = lazyModule(
        loader: (c, n) async {
          if (n == evicted) evictedCalls++;
          return jsonEncode(chapterJson(n));
        },
      );
      for (var i = 1; i <= cap + 38; i++) {
        await m.ensureChapter('GEN', i);
      }
      // в кэше главы 39..cap+38; трогаем раннюю — она становится MRU
      expect(m.chapter('GEN', early), isNotNull);
      // две новые главы вытесняют две самые старые нетронутые
      await m.ensureChapter('GEN', cap + 39);
      await m.ensureChapter('GEN', cap + 40);
      expect(m.chapter('GEN', early), isNotNull, reason: 'тронутая выжила');
      expect(m.chapter('GEN', cap + 40), isNotNull);
      expect(m.chapter('GEN', evicted), isNull, reason: 'старейшая вытеснена');
      expect(m.chapter('GEN', 40), isNull);
      // самовосстановление: вытесненная глава грузится заново
      expect(await m.ensureChapter('GEN', evicted), isNotNull);
      expect(m.chapter('GEN', evicted), isNotNull);
      expect(
        evictedCalls,
        2,
      ); // первая загрузка + перезагрузка после вытеснения
    });

    test('предвыгруженный модуль (без лоадера) — карта не усыхает', () {
      final chapters = <String, ChapterDoc>{
        for (var i = 1; i <= 100; i++)
          'GEN:$i': ChapterDoc(number: i, blocks: const []),
      };
      final m = ModuleDoc(
        id: 'full',
        title: 'Полный',
        language: 'ru',
        books: const [],
        chapters: chapters,
        verseCounts: const {},
      );
      for (var i = 1; i <= 100; i++) {
        m.chapter('GEN', i);
      }
      expect(m.chapters.length, 100);
    });

    test('лента книги: окно последних 3 глав переживает прокрутку', () async {
      final cap = ModuleDoc.kChapterLruCap;
      final m = lazyModule(loader: (c, n) async => jsonEncode(chapterJson(n)));
      // кэш заполнен под потолок: главы 1..cap
      for (var i = 1; i <= cap; i++) {
        await m.ensureChapter('GEN', i);
      }
      // активное окно просмотра — последние 3 главы (перестройка каждый build)
      m.chapter('GEN', cap - 2);
      m.chapter('GEN', cap - 1);
      m.chapter('GEN', cap);
      // дальнейшая прокрутка — вытесняются старейшие нетронутые 1..10
      for (var i = cap + 1; i <= cap + 10; i++) {
        await m.ensureChapter('GEN', i);
      }
      for (var i = cap - 2; i <= cap; i++) {
        expect(m.chapter('GEN', i), isNotNull, reason: 'глава $i вытеснена');
      }
      expect(m.chapters.length, cap);
      expect(m.chapter('GEN', 1), isNull);
    });

    test('типизированный лоадер — тоже ленивый, память ограничена', () async {
      final m = ModuleDoc(
        id: 'typed',
        title: 'Типизированный',
        language: 'ru',
        books: const [],
        chapters: {},
        verseCounts: const {},
        typedChapterLoader: (c, n) async =>
            ChapterDoc(number: n, blocks: const []),
      );
      for (var i = 1; i <= ModuleDoc.kChapterLruCap + 38; i++) {
        await m.ensureChapter('GEN', i);
      }
      expect(m.chapters.length, ModuleDoc.kChapterLruCap);
      expect(m.chapter('GEN', ModuleDoc.kChapterLruCap + 38), isNotNull);
    });
  });
}
