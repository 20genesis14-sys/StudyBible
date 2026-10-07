/// Конверсия версификаций на web: те же `.vrs`-файлы из ассетов
/// (`assets/data/vrs/`), разобранные Dart-портом ядра
/// (`vrs_parser.dart`). Каждый файл читается один раз и кэшируется.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import 'vrs.dart';
import 'vrs_parser.dart';

final Map<String, Versification?> _cache = {};

Future<Versification?> _vrs(String name) async {
  if (_cache.containsKey(name)) return _cache[name];
  try {
    final text = await rootBundle.loadString('assets/data/vrs/$name.vrs');
    return _cache[name] = Versification.parse(name, text);
  } catch (e) {
    debugPrint('[vrs] $name: $e');
    return _cache[name] = null;
  }
}

Future<List<CvPoint>> bridgeConvertVerse(
  String book,
  int chapter,
  int verse,
  String fromVrs,
  String toVrs,
) async {
  final from = await _vrs(fromVrs);
  final to = await _vrs(toVrs);
  if (from == null || to == null) {
    return [(book: book, chapter: chapter, verse: verse)];
  }
  return [
    for (final p in from.convert(to, VerseKey(book, chapter, verse)))
      (book: p.book, chapter: p.chapter, verse: p.verse),
  ];
}
