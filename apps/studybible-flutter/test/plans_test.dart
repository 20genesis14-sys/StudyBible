import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/data.dart';

/// Число глав по 66 книгам (канон sinodal-66) — контрольные суммы
/// против assets/data/plans.json.
const kChapters = {
  'GEN': 50, 'EXO': 40, 'LEV': 27, 'NUM': 36, 'DEU': 34,
  'JOS': 24, 'JDG': 21, 'RUT': 4, '1SA': 31, '2SA': 24,
  '1KI': 22, '2KI': 25, '1CH': 29, '2CH': 36, 'EZR': 10,
  'NEH': 13, 'EST': 10, 'JOB': 42, 'PSA': 150, 'PRO': 31,
  'ECC': 12, 'SNG': 8, 'ISA': 66, 'JER': 52, 'LAM': 5,
  'EZK': 48, 'DAN': 12, 'HOS': 14, 'JOL': 3, 'AMO': 9,
  'OBA': 1, 'JON': 4, 'MIC': 7, 'NAM': 3, 'HAB': 3,
  'ZEP': 3, 'HAG': 2, 'ZEC': 14, 'MAL': 4, 'MAT': 28,
  'MRK': 16, 'LUK': 24, 'JHN': 21, 'ACT': 28, 'ROM': 16,
  '1CO': 16, '2CO': 13, 'GAL': 6, 'EPH': 6, 'PHP': 4,
  'COL': 4, '1TH': 5, '2TH': 3, '1TI': 6, '2TI': 4,
  'TIT': 3, 'PHM': 1, 'HEB': 13, 'JAS': 5, '1PE': 5,
  '2PE': 3, '1JN': 5, '2JN': 1, '3JN': 1, 'JUD': 1, 'REV': 22,
};

Map<String, dynamic> _load() => jsonDecode(
      File('assets/data/plans.json').readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  late List plans;

  setUpAll(() {
    plans = _load()['plans'] as List;
  });

  test('все книги планов — из канона, главы — в пределах', () {
    final catalog = kCatalog.map((e) => e.$1).toSet();
    expect(kChapters.keys.toSet(), catalog);
    for (final p in plans) {
      for (final day in p['days'] as List) {
        expect(day, isNotEmpty, reason: 'пустой день в ${p['id']}');
        for (final r in day as List) {
          final b = r['b'] as String;
          expect(catalog, contains(b), reason: '$b в ${p['id']}');
          expect(r['f'], greaterThanOrEqualTo(1));
          expect(r['t'], lessThanOrEqualTo(kChapters[b]!));
        }
      }
    }
  });

  test('хронологический план покрывает все 66 книг без дыр', () {
    final plan = plans.firstWhere((p) => p['id'] == 'chronological');
    expect(plan['days'], hasLength(366));
    final covered = <String, Set<int>>{};
    for (final day in plan['days'] as List) {
      for (final r in day as List) {
        final b = r['b'] as String;
        covered
            .putIfAbsent(b, () => {})
            .addAll(List.generate(r['t'] - r['f'] + 1, (i) => r['f'] + i));
      }
    }
    for (final e in kChapters.entries) {
      expect(
        covered[e.key],
        Set.of(List.generate(e.value, (i) => i + 1)),
        reason: e.key,
      );
    }
  });

  test('евангельский план — 89 глав Мф+Мк+Лк+Ин', () {
    final plan = plans.firstWhere((p) => p['id'] == 'gospels');
    var ch = 0;
    final books = <String>{};
    for (final day in plan['days'] as List) {
      for (final r in day as List) {
        ch += (r['t'] as int) - (r['f'] as int) + 1;
        books.add(r['b'] as String);
      }
    }
    expect(ch, 89);
    expect(books, {'MAT', 'MRK', 'LUK', 'JHN'});
  });
}
