/// Конверсия стихов между версификациями Paratext (вопрос 8,
/// ADR 0015): общий API для всех платформ — на нативных идёт через
/// FRB-мост в `Versification` ядра, на web — через Dart-порт
/// (`vrs_parser.dart`) над ассетами `assets/data/vrs/`.
library;

import 'models.dart';
import 'vrs_stub.dart'
    if (dart.library.html) 'vrs_web.dart'
    if (dart.library.io) 'vrs_io.dart' as impl;

/// Координата стиха в целевой версификации.
typedef CvPoint = ({String book, int chapter, int verse});

/// Перевести стих [book] [chapter]:[verse] из версификации
/// [fromVrs] в [toVrs] (имена файлов `.vrs`: 'rsc','eng','org',…).
/// Одинаковые версификации — короткий путь без моста.
/// Пусто — соответствия в целевой версификации нет.
Future<List<CvPoint>> convertVerse(
  String book,
  int chapter,
  int verse,
  String fromVrs,
  String toVrs,
) {
  if (fromVrs == toVrs) {
    return Future.value([(book: book, chapter: chapter, verse: verse)]);
  }
  return impl.bridgeConvertVerse(book, chapter, verse, fromVrs, toVrs);
}

/// Текст стиха модуля [m] по конвертированным координатам
/// [targets]: недостающие главы догружаются лениво; несколько
/// соответствий перечисляются с номерами «глава:стих».
/// Тексты одиночных целей мемоизируются в [ModuleDoc.verseTextCache]
/// — соседние сноски часто ссылаются на одни и те же стихи.
/// null — ни одного стиха с текстом.
Future<String?> convertedVerseText(ModuleDoc m, List<CvPoint> targets) async {
  final parts = <String>[];
  final multi = targets.length > 1;
  for (final t in targets) {
    final key = '${t.book}:${t.chapter}:${t.verse}';
    var txt = multi ? null : m.verseTextCache[key];
    if (txt == null) {
      final ch = await m.ensureChapter(t.book, t.chapter);
      if (ch == null) continue;
      txt = verseText(ch, t.verse).trim();
      if (!multi && txt.isNotEmpty) m.verseTextCache[key] = txt;
    }
    if (txt.isEmpty) continue;
    parts.add(multi ? '${t.chapter}:${t.verse} $txt' : txt);
  }
  return parts.isEmpty ? null : parts.join(' ');
}

/// Синхронный вариант для уже загруженных глав — используется
/// построением списков сравнения (каждому стиху второго перевода —
/// его текст с координатой). Стихи без текста пропускаются.
List<({CvPoint point, String text})> compareTexts(
  List<CvPoint> targets,
  ChapterDoc? Function(String book, int chapter) chapterOf,
) {
  final out = <({CvPoint point, String text})>[];
  for (final t in targets) {
    final ch = chapterOf(t.book, t.chapter);
    if (ch == null) continue;
    final txt = verseText(ch, t.verse).trim();
    if (txt.isNotEmpty) out.add((point: t, text: txt));
  }
  return out;
}
