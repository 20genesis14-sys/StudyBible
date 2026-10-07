/// Нативная конверсия версификаций — FRB-мост в
/// `Versification::convert` ядра (см. native_bridge_io).
library;

import 'native_bridge_io.dart' as bridge;
import 'vrs.dart';

Future<List<CvPoint>> bridgeConvertVerse(
  String book,
  int chapter,
  int verse,
  String fromVrs,
  String toVrs,
) => bridge.bridgeConvertVerse(book, chapter, verse, fromVrs, toVrs);
