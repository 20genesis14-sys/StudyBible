/// Нормализация поискового запроса — лёгкий аналог
/// `core::normalize::for_search` для web-моста (сопоставляется со
/// встроенной `fts` модуля по `meta.norm_version`, ADR 0016 п. 11).
/// Вынесена из native_bridge_web.dart ради юнит-тестов: сам мост
/// доступен только в браузере.
///
/// «2» — конечные буквы иврита, маккеф → пробел, ς→σ.
library;

/// Версия правил нормализации, с которой сопоставляется встроенная
/// `fts` модуля (`meta.norm_version`, ADR 0016 п. 11); «2» — конечные
/// буквы иврита, маккеф → пробел, ς→σ.
const String normVersion = '2';

/// Нормализация текста стиха для фоновой `fts` в веб-мосте —
/// те же правила, что и для запроса (`normSearchQuery`); разбиение
/// на слова и пунктуацию делает токенизатор `unicode61`.
String normForIndex(String s) => normSearchQuery(s);

/// Нормализация запроса под колонку `fts.norm`: регистр, ё→е,
/// дореформенные буквы, снятие combining-диакритики, конечные формы
/// иврита, маккеф → пробел, конечная сигма → σ.
///
/// В отличие от Rust-ядра не делает NFD: прекомпонованные буквы с
/// диакритикой (é, ό) остаются как есть — см. OPEN-QUESTIONS.
String normSearchQuery(String s) {
  final b = StringBuffer();
  for (final c in s.toLowerCase().split('')) {
    switch (c) {
      case 'ё':
        b.write('е');
      case 'ѣ':
        b.write('е');
      case 'і':
        b.write('и');
      case 'ѳ':
        b.write('ф');
      case 'ѵ':
        b.write('и');
      // Конечные формы иврита → обычные буквы.
      case 'ך':
        b.write('כ');
      case 'ם':
        b.write('מ');
      case 'ן':
        b.write('נ');
      case 'ף':
        b.write('פ');
      case 'ץ':
        b.write('צ');
      // Маккеф — разделитель слов.
      case '־':
        b.write(' ');
      // Конечная сигма → обычная (Σ уже даёт σ).
      case 'ς':
        b.write('σ');
      default:
        b.write(c);
    }
  }
  // Combining-диапазоны (ударения, огласовки) снимаем.
  return b.toString().replaceAll(
    RegExp(
      '[\\u0300-\\u036F\\u0483-\\u0489\\u0591-\\u05BD\\u0610-\\u061A'
      '\\u064B-\\u065F\\u0670\\u1AB0-\\u1AFF\\u1DC0-\\u1DFF'
      '\\u20D0-\\u20FF\\uFE20-\\uFE2F\\u00AD\\u05BF\\u05C1\\u05C2'
      '\\u05C4\\u05C5\\u05C7]',
    ),
    '',
  );
}

// ---------- операторы запроса («…» фраза, w* префикс, ? и внутренняя
// * — glob; зеркало Term/parse_query в crates/studybible-store/src/search.rs) ----------

/// Лексема запроса: `word` | `prefix` | `phrase` | `glob`.
typedef SearchTerm = ({String kind, String value});

/// Буквенно-цифровые раны нормализованного текста — как токены
/// `unicode61`: знаки препинания в слово не входят («свет.» → «свет»).
List<String> normTokens(String norm) => [
  for (final m in RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(norm))
    m[0]!,
];

/// Разбор запроса в лексемы; `?` или `*` внутри слова дают `glob`.
List<SearchTerm> parseSearchQuery(String query) {
  final terms = <SearchTerm>[];
  final chars = query.split('');
  var i = 0;
  while (i < chars.length) {
    final c = chars[i];
    if (c.trim().isEmpty) {
      i++;
      continue;
    }
    if (c == '"') {
      i++;
      final buf = StringBuffer();
      while (i < chars.length && chars[i] != '"') {
        buf.write(chars[i]);
        i++;
      }
      if (i < chars.length) i++; // закрывающая кавычка
      final norm = normTokens(normSearchQuery(buf.toString())).join(' ');
      if (norm.isNotEmpty) terms.add((kind: 'phrase', value: norm));
      continue;
    }
    final tok = StringBuffer();
    while (i < chars.length && chars[i].trim().isNotEmpty && chars[i] != '"') {
      tok.write(chars[i]);
      i++;
    }
    final norm = normSearchQuery(tok.toString()).trim();
    if (norm.isEmpty) continue;
    final stem = norm.replaceAll(RegExp(r'\*+$'), '');
    if (norm.endsWith('*') &&
        stem.isNotEmpty &&
        !stem.contains('*') &&
        !stem.contains('?')) {
      terms.add((kind: 'prefix', value: stem));
    } else if (norm.contains('*') || norm.contains('?')) {
      terms.add((kind: 'glob', value: norm));
    } else {
      terms.add((kind: 'word', value: norm));
    }
  }
  return terms;
}

/// FTS5 MATCH для лексем без `glob`.
String ftsQuery(List<SearchTerm> terms) => [
  for (final t in terms)
    switch (t.kind) {
      'prefix' => '"${t.value.replaceAll('"', '""')}"*',
      _ => '"${t.value.replaceAll('"', '""')}"',
    },
].join(' AND ');

/// Glob `*`/`?` по одному слову — двухуказательный матчер
/// с откатом к последней `*`.
bool globWord(String pat, String word) {
  final p = pat.split('');
  final w = word.split('');
  var i = 0, j = 0, star = -1, mark = 0;
  while (j < w.length) {
    if (i < p.length && (p[i] == '?' || p[i] == w[j])) {
      i++;
      j++;
    } else if (i < p.length && p[i] == '*') {
      star = i;
      mark = j;
      i++;
    } else if (star >= 0) {
      i = star + 1;
      mark++;
      j = mark;
    } else {
      return false;
    }
  }
  while (i < p.length && p[i] == '*') {
    i++;
  }
  return i == p.length;
}

bool _wordMatches(SearchTerm t, String w) => switch (t.kind) {
  'word' => w == t.value,
  'prefix' => w.startsWith(t.value),
  'glob' => globWord(t.value, w),
  _ => false,
};

/// Проверка нормализованного текста стиха по всем лексемам (AND);
/// при совпадении — сниппет: текст с `[` `]` вокруг совпавших слов.
String? scanMatch(String norm, List<SearchTerm> terms) {
  final words = normTokens(norm);
  final mark = List<bool>.filled(words.length, false);
  for (final t in terms) {
    if (t.kind == 'phrase') {
      final ph = t.value.split(' ');
      var found = false;
      if (ph.length <= words.length) {
        for (var i = 0; i <= words.length - ph.length; i++) {
          var eq = true;
          for (var k = 0; k < ph.length; k++) {
            if (words[i + k] != ph[k]) {
              eq = false;
              break;
            }
          }
          if (eq) {
            for (var k = 0; k < ph.length; k++) {
              mark[i + k] = true;
            }
            found = true;
          }
        }
      }
      if (!found) return null;
    } else {
      var found = false;
      for (var i = 0; i < words.length; i++) {
        if (_wordMatches(t, words[i])) {
          mark[i] = true;
          found = true;
        }
      }
      if (!found) return null;
    }
  }
  final b = StringBuffer();
  for (var i = 0; i < words.length; i++) {
    if (b.isNotEmpty) b.write(' ');
    if (mark[i]) b.write('[');
    b.write(words[i]);
    if (mark[i]) b.write(']');
  }
  return b.toString();
}
