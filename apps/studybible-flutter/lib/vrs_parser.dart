/// Парсер версификаций Paratext `.vrs` — точный порт
/// `crates/studybible-core/src/versification.rs` (используется на web,
/// где Rust-моста нет; parity проверяется тестами vrs_test.dart).
///
/// Соответствия в `.vrs` описывают переход «эта версификация → org».
/// Стихи 0 — надписания. Неравные диапазоны сопоставляются по порядку,
/// лишние стихи длинной стороны относятся к последнему стиху короткой.
library;

/// Координата стиха: код книги + глава + стих + буквенный сегмент.
class VerseKey {
  final String book; // 'GEN','PSA',... — 3 символа [A-Z0-9]
  final int chapter;
  final int verse;

  /// Буквенная часть стиха (`1:1a` → 1): 0 = весь стих, 1..26 = a..z.
  final int segment;

  const VerseKey(this.book, this.chapter, this.verse, [this.segment = 0]);

  static bool _bookOk(String s) =>
      s.length == 3 &&
      s.codeUnits.every(
        (c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39),
      );

  /// `GEN 1:1`, `GEN 1:1a`; сегмент — одна строчная буква после номера.
  static VerseKey? parse(String s) {
    final parts = s.trim().split(' ');
    if (parts.length != 2) return null;
    final cv = parts[1].trim().split(':');
    if (cv.length != 2) return null;
    final vdigits = _leadingDigits(cv[1]);
    if (vdigits.isEmpty) return null;
    var seg = 0;
    if (vdigits.length < cv[1].length) {
      final sc = cv[1].codeUnitAt(vdigits.length);
      if (sc >= 0x61 && sc <= 0x7A) seg = sc - 0x61 + 1;
    }
    final c = int.tryParse(cv[0]);
    final v = int.tryParse(vdigits);
    if (c == null || v == null || !_bookOk(parts[0])) return null;
    return VerseKey(parts[0], c, v, seg);
  }

  static String _leadingDigits(String s) {
    final b = StringBuffer();
    for (final c in s.codeUnits) {
      if (c >= 0x30 && c <= 0x39) {
        b.writeCharCode(c);
      } else {
        break;
      }
    }
    return b.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is VerseKey &&
      book == other.book &&
      chapter == other.chapter &&
      verse == other.verse &&
      segment == other.segment;

  @override
  int get hashCode => Object.hash(book, chapter, verse, segment);

  @override
  String toString() => segment == 0
      ? '$book $chapter:$verse'
      : '$book $chapter:$verse${String.fromCharCode(0x60 + segment)}';
}

/// Разобранная версификация (.vrs).
class Versification {
  final String name;
  final Map<String, List<int>> chapters = {};
  final Map<VerseKey, List<VerseKey>> _toOrg = {};
  final Map<VerseKey, List<VerseKey>> _fromOrg = {};

  /// Строки-соответствия, которые не удалось разобрать (для аудита).
  final List<String> skipped = [];

  Versification(this.name);

  factory Versification.parse(String name, String text) {
    final v = Versification(name);
    var n = 0;
    for (final raw in text.split('\n')) {
      n++;
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      final c0 = line.codeUnitAt(0);
      final okStart =
          (c0 >= 0x41 && c0 <= 0x5A) || (c0 >= 0x30 && c0 <= 0x39);
      if (!okStart) continue;
      final eq = line.indexOf('=');
      if (eq >= 0) {
        // Искажённое соответствие пропускаем и записываем —
        // хуже, чем падение всей версификации.
        final l = _expand(line.substring(0, eq));
        final r = _expand(line.substring(eq + 1));
        if (l == null || r == null) {
          v.skipped.add('$name.vrs:$n: $raw');
          continue;
        }
        final len = l.length > r.length ? l.length : r.length;
        for (var i = 0; i < len; i++) {
          final a = l[i < l.length ? i : l.length - 1];
          final b = r[i < r.length ? i : r.length - 1];
          _pushUnique(v._toOrg.putIfAbsent(a, () => []), b);
          _pushUnique(v._fromOrg.putIfAbsent(b, () => []), a);
        }
      } else {
        final parts = line.split(RegExp(r'\s+'));
        final book = parts[0];
        if (!_bookOkStatic(book)) {
          throw FormatException('$name.vrs:$n: $raw');
        }
        final sizes = <int>[];
        var bad = false;
        for (var i = 1; i < parts.length; i++) {
          final colon = parts[i].indexOf(':');
          final num = colon < 0
              ? null
              : int.tryParse(parts[i].substring(colon + 1));
          if (num == null) {
            bad = true;
            break;
          }
          sizes.add(num);
        }
        if (bad) throw FormatException('$name.vrs:$n: $raw');
        v.chapters[book] = sizes;
      }
    }
    return v;
  }

  static bool _bookOkStatic(String s) =>
      s.length == 3 &&
      s.codeUnits.every(
        (c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39),
      );

  static void _pushUnique(List<VerseKey> v, VerseKey k) {
    if (!v.contains(k)) v.add(k);
  }

  /// `BOOK c:v` или `BOOK c:v-w` → стихи по порядку.
  static List<VerseKey>? _expand(String side) {
    final s = side.trim();
    final dash = s.indexOf('-');
    if (dash < 0) {
      final k = VerseKey.parse(s);
      return k == null ? null : [k];
    }
    final start = VerseKey.parse(s.substring(0, dash));
    final endStr = VerseKey._leadingDigits(s.substring(dash + 1));
    if (start == null || endStr.isEmpty) return null;
    final end = int.tryParse(endStr);
    if (end == null || start.verse > end) return null;
    return [
      for (var v = start.verse; v <= end; v++)
        VerseKey(start.book, start.chapter, v, start.segment),
    ];
  }

  /// Стихи org, соответствующие стиху этой версификации
  /// (без соответствия — тот же номер).
  List<VerseKey> toOrg(VerseKey k) =>
      _toOrg[k]?.toList() ?? [k];

  /// Стихи этой версификации, соответствующие стиху org.
  List<VerseKey> fromOrg(VerseKey k) {
    final v = _fromOrg[k];
    if (v != null) return v.toList();
    if (_toOrg.containsKey(k)) return const [];
    return [k];
  }

  /// Перевод стиха между версификациями через org
  /// (результат отсортирован по book/chapter/verse/segment, без
  /// дублей — зеркало BTreeSet в Rust-версии).
  ///
  /// `.vrs`-соответствия оперируют целыми стихами, поэтому сегмент в
  /// поиске не участвует: маппится стих целиком, исходный сегмент
  /// переносится на каждый результат, у которого он не задан
  /// (0 — без изменений). Ручная `verse_map` ядра на web не портирована.
  List<VerseKey> convert(Versification to, VerseKey k) {
    final whole = VerseKey(k.book, k.chapter, k.verse);
    final seen = <VerseKey>{};
    final out = <VerseKey>[];
    for (final o in toOrg(whole)) {
      for (var p in to.fromOrg(o)) {
        // Свой сегмент из .vrs (ESG 10:3a) важнее переносимого.
        if (p.segment == 0 && k.segment != 0) {
          p = VerseKey(p.book, p.chapter, p.verse, k.segment);
        }
        if (seen.add(p)) out.add(p);
      }
    }
    out.sort((a, b) {
      final t = a.book.compareTo(b.book);
      if (t != 0) return t;
      final c = a.chapter.compareTo(b.chapter);
      if (c != 0) return c;
      final v = a.verse.compareTo(b.verse);
      if (v != 0) return v;
      return a.segment.compareTo(b.segment);
    });
    return out;
  }
}
