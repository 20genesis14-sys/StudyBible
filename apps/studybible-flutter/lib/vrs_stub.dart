/// Фоллбэк конверсии версификаций без моста — тот же номер
/// (используется только при неразрешённом conditional import).
library;

import 'vrs.dart';

Future<List<CvPoint>> bridgeConvertVerse(
  String book,
  int chapter,
  int verse,
  String fromVrs,
  String toVrs,
) async =>
    [(book: book, chapter: chapter, verse: verse)];
