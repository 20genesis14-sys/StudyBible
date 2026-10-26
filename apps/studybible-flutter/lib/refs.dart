/// Разбор библейских ссылок внутри текста сносок: «Быт 1:1», «Пс 22:1»,
/// «1 Кор 15:45», «Exodus 3:3-4». Нужен, чтобы делать параллельные места
/// гиперссылками в панели «Сноски и параллельные».
library;

/// Распознанная ссылка: код книги каталога, глава и стих начала.
class Ref {
  final String book; // код kCatalog ('GEN', 'JHN', …)
  final int chapter;
  final int verse;

  /// Конец диапазона «Ин 1:1–3» → 3; для одиночного стиха == verse.
  final int verseEnd;
  const Ref(this.book, this.chapter, this.verse, [int? end])
    : verseEnd = end ?? verse;

  @override
  String toString() => '$book $chapter:$verse';
}

/// Сокращения книг → коды каталога. Ключи — в нижнем регистре, без точки.
const Map<String, String> _ruBooks = {
  'быт': 'GEN',
  'бытие': 'GEN',
  'исх': 'EXO',
  'исход': 'EXO',
  'лев': 'LEV',
  'левит': 'LEV',
  'чис': 'NUM',
  'числ': 'NUM',
  'числа': 'NUM',
  'втор': 'DEU',
  'нав': 'JOS',
  'ис нав': 'JOS',
  'и нав': 'JOS',
  'иисуса навина': 'JOS',
  'суд': 'JDG',
  'судей': 'JDG',
  'руф': 'RUT',
  'руфь': 'RUT',
  '1 цар': '1SA',
  '1цар': '1SA',
  '1 сам': '1SA',
  '2 цар': '2SA',
  '2цар': '2SA',
  '2 сам': '2SA',
  '3 цар': '1KI',
  '3цар': '1KI',
  '3царств': '1KI',
  '4 цар': '2KI',
  '4цар': '2KI',
  '4царств': '2KI',
  '1 пар': '1CH',
  '1пар': '1CH',
  '1 хрон': '1CH',
  '1 лет': '1CH',
  '1лет': '1CH',
  '1 летопись': '1CH',
  '2 пар': '2CH',
  '2пар': '2CH',
  '2 хрон': '2CH',
  '2 лет': '2CH',
  '2лет': '2CH',
  '2 летопись': '2CH',
  'езд': 'EZR',
  'ездра': 'EZR',
  'ездры': 'EZR',
  'неем': 'NEH',
  'неемия': 'NEH',
  'эсф': 'EST',
  'эсфирь': 'EST',
  'иов': 'JOB',
  'пс': 'PSA',
  'псал': 'PSA',
  'псалом': 'PSA',
  'псалмы': 'PSA',
  'псалтирь': 'PSA',
  'прит': 'PRO',
  'притч': 'PRO',
  'притчи': 'PRO',
  'еккл': 'ECC',
  'эккл': 'ECC',
  'экклезиаст': 'ECC',
  'экклезиаста': 'ECC',
  'песн': 'SNG',
  'пес': 'SNG',
  'песня соломона': 'SNG',
  'песнь песней': 'SNG',
  'ис': 'ISA',
  'иса': 'ISA',
  'исайя': 'ISA',
  'иер': 'JER',
  'иеремия': 'JER',
  'плач': 'LAM',
  'иез': 'EZK',
  'иезекииль': 'EZK',
  'дан': 'DAN',
  'даниил': 'DAN',
  'ос': 'HOS',
  'осия': 'HOS',
  'иоил': 'JOL',
  'иоиль': 'JOL',
  'ам': 'AMO',
  'амос': 'AMO',
  'авд': 'OBA',
  'авдия': 'OBA',
  'ион': 'JON',
  'иона': 'JON',
  'ионы': 'JON',
  'мих': 'MIC',
  'михей': 'MIC',
  'михея': 'MIC',
  'наум': 'NAM',
  'авв': 'HAB',
  'аввакум': 'HAB',
  'аввакума': 'HAB',
  'соф': 'ZEP',
  'софония': 'ZEP',
  'софонии': 'ZEP',
  'агг': 'HAG',
  'аггея': 'HAG',
  'зах': 'ZEC',
  'захария': 'ZEC',
  'захарии': 'ZEC',
  'мал': 'MAL',
  'малахия': 'MAL',
  'малахии': 'MAL',
  'мф': 'MAT',
  'матф': 'MAT',
  'матфея': 'MAT',
  'мк': 'MRK',
  'мар': 'MRK',
  'марка': 'MRK',
  'лк': 'LUK',
  'лук': 'LUK',
  'луки': 'LUK',
  'ин': 'JHN',
  'иоан': 'JHN',
  'иоанна': 'JHN',
  'деян': 'ACT',
  'деяния': 'ACT',
  'иак': 'JAS',
  'иаков': 'JAS',
  'иакова': 'JAS',
  '1 пет': '1PE',
  '1пет': '1PE',
  '1 петра': '1PE',
  '2 пет': '2PE',
  '2пет': '2PE',
  '2 петра': '2PE',
  '1 ин': '1JN',
  '1ин': '1JN',
  '1 иоан': '1JN',
  '1 иоанна': '1JN',
  '2 ин': '2JN',
  '2ин': '2JN',
  '2 иоан': '2JN',
  '2 иоанна': '2JN',
  '3 ин': '3JN',
  '3ин': '3JN',
  '3 иоан': '3JN',
  '3 иоанна': '3JN',
  'иуд': 'JUD',
  'иуда': 'JUD',
  'иуды': 'JUD',
  'рим': 'ROM',
  'римл': 'ROM',
  'римлянам': 'ROM',
  '1 кор': '1CO',
  '1кор': '1CO',
  '1 коринф': '1CO',
  '1 коринфянам': '1CO',
  '2 кор': '2CO',
  '2кор': '2CO',
  '2 коринф': '2CO',
  '2 коринфянам': '2CO',
  'гал': 'GAL',
  'галат': 'GAL',
  'галатам': 'GAL',
  'галатов': 'GAL',
  'эф': 'EPH',
  'еф': 'EPH',
  'ефесянам': 'EPH',
  'ефес': 'EPH',
  'флп': 'PHP',
  'фил': 'PHP',
  'филипп': 'PHP',
  'кол': 'COL',
  'колос': 'COL',
  '1 фес': '1TH',
  '1фес': '1TH',
  '1 фесс': '1TH',
  '2 фес': '2TH',
  '2фес': '2TH',
  '2 фесс': '2TH',
  '1 тим': '1TI',
  '1тим': '1TI',
  '1 тимоф': '1TI',
  '1 тимофею': '1TI',
  '2 тим': '2TI',
  '2тим': '2TI',
  '2 тимоф': '2TI',
  '2 тимофею': '2TI',
  'тит': 'TIT',
  'тита': 'TIT',
  'титу': 'TIT',
  'флм': 'PHM',
  'филим': 'PHM',
  'филимону': 'PHM',
  'евр': 'HEB',
  'евреям': 'HEB',
  'евреев': 'HEB',
  'откр': 'REV',
  'отк': 'REV',
  'откровение': 'REV',
  'откровения': 'REV',
  'апок': 'REV',
};

/// Английские названия (для сносок WEB/KJV, например «Exodus 3:3-4»).
const Map<String, String> _enBooks = {
  'genesis': 'GEN',
  'exodus': 'EXO',
  'leviticus': 'LEV',
  'numbers': 'NUM',
  'deuteronomy': 'DEU',
  'joshua': 'JOS',
  'judges': 'JDG',
  'ruth': 'RUT',
  '1 samuel': '1SA',
  '2 samuel': '2SA',
  '1 kings': '1KI',
  '2 kings': '2KI',
  '1 chronicles': '1CH',
  '2 chronicles': '2CH',
  'ezra': 'EZR',
  'nehemiah': 'NEH',
  'esther': 'EST',
  'job': 'JOB',
  'psalm': 'PSA',
  'psalms': 'PSA',
  'proverbs': 'PRO',
  'ecclesiastes': 'ECC',
  'song of solomon': 'SNG',
  'isaiah': 'ISA',
  'jeremiah': 'JER',
  'lamentations': 'LAM',
  'ezekiel': 'EZK',
  'daniel': 'DAN',
  'hosea': 'HOS',
  'joel': 'JOL',
  'amos': 'AMO',
  'obadiah': 'OBA',
  'jonah': 'JON',
  'micah': 'MIC',
  'nahum': 'NAM',
  'habakkuk': 'HAB',
  'zephaniah': 'ZEP',
  'haggai': 'HAG',
  'zechariah': 'ZEC',
  'malachi': 'MAL',
  'matthew': 'MAT',
  'mark': 'MRK',
  'luke': 'LUK',
  'john': 'JHN',
  'acts': 'ACT',
  'romans': 'ROM',
  '1 corinthians': '1CO',
  '2 corinthians': '2CO',
  'galatians': 'GAL',
  'ephesians': 'EPH',
  'philippians': 'PHP',
  'colossians': 'COL',
  '1 thessalonians': '1TH',
  '2 thessalonians': '2TH',
  '1 timothy': '1TI',
  '2 timothy': '2TI',
  'titus': 'TIT',
  'philemon': 'PHM',
  'hebrews': 'HEB',
  'james': 'JAS',
  '1 peter': '1PE',
  '2 peter': '2PE',
  '1 john': '1JN',
  '2 john': '2JN',
  '3 john': '3JN',
  'jude': 'JUD',
  'revelation': 'REV',
};

/// OSIS-аббревиатуры — языконезависимые ссылки слоя параллельных
/// (ADR 0023: текст x-спанов слоя «Ps 104:30»). Проверяются после
/// полных имён, чтобы не перекрывать их (job/acts/mark…).
const Map<String, String> _osisBooks = {
  'gen': 'GEN',
  'exod': 'EXO',
  'lev': 'LEV',
  'num': 'NUM',
  'deut': 'DEU',
  'josh': 'JOS',
  'judg': 'JDG',
  'ruth': 'RUT',
  '1sam': '1SA',
  '2sam': '2SA',
  '1kgs': '1KI',
  '2kgs': '2KI',
  '1chr': '1CH',
  '2chr': '2CH',
  'ezra': 'EZR',
  'neh': 'NEH',
  'esth': 'EST',
  'job': 'JOB',
  'ps': 'PSA',
  'prov': 'PRO',
  'eccl': 'ECC',
  'song': 'SNG',
  'isa': 'ISA',
  'jer': 'JER',
  'lam': 'LAM',
  'ezek': 'EZK',
  'dan': 'DAN',
  'hos': 'HOS',
  'joel': 'JOL',
  'amos': 'AMO',
  'obad': 'OBA',
  'jonah': 'JON',
  'mic': 'MIC',
  'nah': 'NAM',
  'hab': 'HAB',
  'zeph': 'ZEP',
  'hag': 'HAG',
  'zech': 'ZEC',
  'mal': 'MAL',
  'matt': 'MAT',
  'mark': 'MRK',
  'luke': 'LUK',
  'acts': 'ACT',
  'rom': 'ROM',
  '1cor': '1CO',
  '2cor': '2CO',
  'gal': 'GAL',
  'eph': 'EPH',
  'phil': 'PHP',
  'col': 'COL',
  '1thess': '1TH',
  '2thess': '2TH',
  '1tim': '1TI',
  '2tim': '2TI',
  'titus': 'TIT',
  'phlm': 'PHM',
  'heb': 'HEB',
  'jas': 'JAS',
  '1pet': '1PE',
  '2pet': '2PE',
  '1john': '1JN',
  '2john': '2JN',
  '3john': '3JN',
  'rev': 'REV',
};

/// Паттерн «Книга Гл:Ст»: книга — буквенный префикс (1-3 слова, допускает
/// ведущую цифру и пробел), далее глава, двоеточие, стих или диапазон.
/// Буква части стиха («1:1a», ADR 0016) входит в подсветку ссылки,
/// навигация идёт на целый стих.
final RegExp _pattern = RegExp(
  r'((?:[1-4]\s*)?(?:[A-ZА-ЯЁ][a-zа-яё\.]*(?:\s+[a-zа-яё\.]+){0,2}))\s+(\d{1,3})\s*[:：,]\s*(\d{1,3}[a-e]?)(?:\s*[-–—]\s*(\d{1,3}[a-e]?))?',
  unicode: true,
);

/// Разрезать текст на сегменты: чередование (текст | ссылка).
/// Для каждой ссылки — её позиция в исходном тексте и [Ref].
class RefMatch {
  final Ref ref;
  final int start;
  final int end;
  const RefMatch(this.ref, this.start, this.end);
}

/// Найти все ссылки «Книга Гл:Ст» в тексте (дубли и границы не проверяются —
/// навигация сама ограничится каталогом и числом глав модуля).
List<RefMatch> findRefs(String text) {
  final out = <RefMatch>[];
  for (final m in _pattern.allMatches(text)) {
    final book = _bookOf(m.group(1)!);
    if (book == null) continue;
    final ch = int.tryParse(m.group(2)!) ?? 0;
    // Буква части стиха (1:1a) — в подсветке, для навигации отрезается.
    final vs =
        int.tryParse(m.group(3)!.replaceAll(RegExp('[a-e]\$'), '')) ?? 0;
    final ve = m.group(4) != null
        ? int.tryParse(m.group(4)!.replaceAll(RegExp('[a-e]\$'), ''))
        : null;
    if (ch <= 0 || vs <= 0) continue;
    out.add(RefMatch(Ref(book, ch, vs, ve), m.start, m.end));
  }
  return out;
}

/// Панельная ссылка второго яруса (`openbible-xrefs`): стих главы
/// в версификации модуля + отформатированные цели.
class PanelRef {
  const PanelRef(this.verse, this.refs);

  final int verse;
  final String refs;
}

/// Цель слойной ссылки с типами связи (`xrefs_meta`, ADR 0023):
/// стих в версификации модуля, метка «Пс 22:16b», типы (quote, para,
/// verbal, historical, thematic, …) и семейный балл ×100.
class XrefMeta {
  const XrefMeta(this.verse, this.label, this.kinds, this.score);

  final int verse;
  final String label;
  final List<String> kinds;
  final int score;
}

/// Переписать имена книг в ссылках [text] через [bookName]
/// (код → «Лев»/«Lev» по языку интерфейса и раскладке названий);
/// числа, диапазоны и пунктуация остаются как в оригинале.
/// Применяется к слойным x-ссылкам (attrs `src="layer"`), которые
/// приходят с OSIS-именами книг (ADR 0023).
String localizeRefs(String text, String Function(String code) bookName) {
  final buf = StringBuffer();
  var pos = 0;
  for (final m in _pattern.allMatches(text)) {
    final book = _bookOf(m.group(1)!);
    if (book == null) continue;
    buf.write(text.substring(pos, m.start));
    buf.write(bookName(book));
    buf.write(text.substring(m.start + m.group(1)!.length, m.end));
    pos = m.end;
  }
  buf.write(text.substring(pos));
  return buf.toString();
}

/// Паттерн одиночного запроса-ссылки для омнибокса поиска:
/// регистронезависимо распознаёт «Ин 3:16», «ин 3 16», «Быт 1»,
/// «1Кор 13:4-7», «John 3:16». Если стих не указан («Быт 1»),
/// возвращает стих 1.
final RegExp _queryRefPattern = RegExp(
  r'^\s*((?:[1-4]\s*)?[A-Za-zА-Яа-яЁё\.]+(?:\s+[A-Za-zА-Яа-яЁё\.]+){0,2})\s+(\d{1,3})(?:\s*[:：,\.\s]\s*(\d{1,3}[a-e]?)(?:\s*[-–—]\s*(\d{1,3}[a-e]?))?)?\s*$',
  unicode: true,
);

/// Распознать библейскую ссылку, введённую в строку поиска целиком.
Ref? parseQueryRef(String query) {
  final m = _queryRefPattern.firstMatch(query);
  if (m != null) {
    final book = _bookOf(m.group(1)!);
    final ch = int.tryParse(m.group(2)!) ?? 0;
    if (book != null && ch > 0) {
      final rawVs = m.group(3);
      final vs = rawVs == null
          ? 1
          : (int.tryParse(rawVs.replaceAll(RegExp('[a-e]\$'), '')) ?? 0);
      final rawVe = m.group(4);
      final ve = rawVe != null
          ? int.tryParse(rawVe.replaceAll(RegExp('[a-e]\$'), ''))
          : null;
      if (vs > 0) return Ref(book, ch, vs, ve);
    }
  }
  final refs = findRefs(query.trim());
  if (refs.length == 1 &&
      refs.first.start == 0 &&
      refs.first.end == query.trim().length) {
    return refs.first.ref;
  }
  return null;
}

String? _bookOf(String raw) {
  var s = raw.trim().toLowerCase().replaceAll(RegExp(r'\.$'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  return _ruBooks[s] ?? _enBooks[s] ?? _osisBooks[s];
}
