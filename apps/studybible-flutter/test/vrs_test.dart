/// Версификации: Dart-порт парсера `.vrs` на тех же файлах, что
/// встроены в Rust-ядро (`data/versification/` скопированы в
/// `assets/data/vrs/`) — результаты сверены с `Versification::convert`
/// ядра (crates/studybible-core/tests/versification_ext.rs +
/// канонические пары rsc↔eng).
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/models.dart';
import 'package:studybible/vrs.dart';
import 'package:studybible/vrs_parser.dart';

Future<Versification> _load(String name) async =>
    Versification.parse(name, await rootBundle.loadString(
      'assets/data/vrs/$name.vrs',
    ));

List<VerseKey> _conv(Versification from, Versification to, int c, int v) =>
    from.convert(to, VerseKey('PSA', c, v));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('vrs-файлы парсятся; исправленные строки vul не в skipped', () async {
    for (final n in ['org', 'eng', 'lxx', 'vul', 'rso', 'rsc']) {
      final v = await _load(n);
      expect(v.chapters, isNotEmpty, reason: n);
    }
    final vul = await _load('vul');
    expect(
      vul.skipped.where((s) => s.contains('DAG')).toList(),
      isEmpty,
      reason: 'DAG 3:52-53, SUS 1:1-63, BEL 1:1-42 исправлены',
    );
  });

  test('rsc → eng: Пс 89 → Пс 90 (надписание и неравные диапазоны)',
      () async {
    final rsc = await _load('rsc');
    final eng = await _load('eng');
    expect(_conv(rsc, eng, 89, 0), [VerseKey('PSA', 90, 0)]);
    expect(_conv(rsc, eng, 89, 1), [VerseKey('PSA', 90, 0)]);
    expect(_conv(rsc, eng, 89, 2), [VerseKey('PSA', 90, 1)]);
    expect(
      _conv(rsc, eng, 89, 6),
      [VerseKey('PSA', 90, 5), VerseKey('PSA', 90, 6)],
    );
  });

  test('rsc → eng: Пс 141 → Пс 142', () async {
    final rsc = await _load('rsc');
    final eng = await _load('eng');
    expect(_conv(rsc, eng, 141, 0), [VerseKey('PSA', 142, 0)]);
    expect(_conv(rsc, eng, 141, 1), [VerseKey('PSA', 142, 1)]);
  });

  test('eng → rsc: обратное сопоставление собирает пару стихов', () async {
    final rsc = await _load('rsc');
    final eng = await _load('eng');
    expect(
      _conv(eng, rsc, 90, 0),
      [VerseKey('PSA', 89, 0), VerseKey('PSA', 89, 1)],
    );
    expect(_conv(eng, rsc, 90, 5), [VerseKey('PSA', 89, 6)]);
    expect(_conv(eng, rsc, 90, 6), [VerseKey('PSA', 89, 6)]);
  });

  test('vul → eng: Сусанна и Песнь трёх отроков (DAG↔SUS/S3Y)',
      () async {
    final vul = await _load('vul');
    final eng = await _load('eng');
    expect(
      vul.convert(eng, VerseKey('DAG', 13, 63)),
      [VerseKey('DAG', 13, 63)],
    );
    // DAG 3:53 → org S3Y 1:31; у eng стихи S3Y отображены В org,
    // а не из него — соответствия нет (пусто, как и в Rust).
    expect(vul.convert(eng, VerseKey('DAG', 3, 53)), isEmpty);
  });

  test('compareTexts: текст каждого соответствия со своим номером', () {
    // Фейковая глава eng Пс 90: стихи 0,5,6.
    ChapterDoc? chapterOf(String book, int ch) {
      if (book != 'PSA' || ch != 90) return null;
      return ChapterDoc(
        number: 90,
        blocks: [
          BlockDoc(kind: BlockKind.paragraph, marker: 'q', spans: const [
            VerseSpanDoc(0),
            TextSpanDoc(text: 'A prayer. ', style: '', attrs: ''),
            VerseSpanDoc(5),
            TextSpanDoc(text: 'five. ', style: '', attrs: ''),
            VerseSpanDoc(6),
            TextSpanDoc(text: 'six. ', style: '', attrs: ''),
          ]),
        ],
      );
    }

    final items = compareTexts(
      [
        (book: 'PSA', chapter: 90, verse: 5),
        (book: 'PSA', chapter: 90, verse: 6),
        (book: 'PSA', chapter: 90, verse: 7), // нет — пропуск
      ],
      chapterOf,
    );
    expect(items.length, 2);
    expect(items[0].point.verse, 5);
    expect(items[0].text, 'five.');
    expect(items[1].point.verse, 6);

    // Надписание: стих 0 выбирается той же механикой.
    final sup = compareTexts([
      (book: 'PSA', chapter: 90, verse: 0),
    ], chapterOf);
    expect(sup.single.text, 'A prayer.');
  });
}
