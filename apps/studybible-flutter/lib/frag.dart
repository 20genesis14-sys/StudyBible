/// Текстовый селектор куска стиха — поле `frag` записи (userdata схема 4).
/// `{exact, pre, post}`; пустая строка в записи — выделение всего стиха.
library;

import 'dart:convert';

/// Диапазон в индексах строки Dart (UTF-16).
typedef TextRange = ({int s, int e});

/// JSON поля `frag`.
String fragJson(String exact, String pre, String post) =>
    jsonEncode({'exact': exact, 'pre': pre, 'post': post});

/// Поля селектора из JSON; битый/пустой → null.
({String exact, String pre, String post})? fragParse(String frag) {
  if (frag.isEmpty) return null;
  try {
    final m = jsonDecode(frag);
    if (m is! Map) return null;
    final exact = '${m['exact'] ?? ''}';
    if (exact.isEmpty) return null;
    return (
      exact: exact,
      pre: '${m['pre'] ?? ''}',
      post: '${m['post'] ?? ''}',
    );
  } catch (_) {
    return null;
  }
}

/// Байтовые диапазоны моста `[s0,e0,s1,e1,…]` → UTF-16 индексы [text].
List<TextRange> byteToUtf16(String text, List<int> pairs) {
  final b = utf8.encode(text);
  final out = <TextRange>[];
  for (var i = 0; i + 1 < pairs.length; i += 2) {
    final bs = pairs[i].clamp(0, b.length);
    final be = pairs[i + 1].clamp(0, b.length);
    if (be <= bs) continue;
    out.add((
      s: utf8.decode(b.sublist(0, bs)).length,
      e: utf8.decode(b.sublist(0, be)).length,
    ));
  }
  return out;
}

// ---------- Dart-порт find_frag (ядро crates/studybible-core/src/frag.rs) --
// Нужен web-сборке (нет нативного моста): алгоритм обязан совпадать
// с ядром — нормализация «буквы/цифры + схлопнутые пробелы», контекст
// сравнивается вплотную к фрагменту.

final _alnum = RegExp(r'[\p{L}\p{N}]', unicode: true);

List<String> _norm(String s) {
  final out = <String>[];
  var prevWs = true;
  for (final c in s.split('')) {
    if (c.trim().isEmpty) {
      if (prevWs) continue;
      out.add(' ');
      prevWs = true;
    } else if (_alnum.hasMatch(c)) {
      out.add(c);
      prevWs = false;
    }
  }
  if (out.isNotEmpty && out.last == ' ') out.removeLast();
  return out;
}

/// Диапазоны вхождений селектора в [text] — в индексах строки (UTF-16).
/// Порт `studybible_core::frag::find_frag`.
List<TextRange> findFragRanges(
  String text,
  String exact, [
  String pre = '',
  String post = '',
]) {
  final t = _norm(text);
  final e = _norm(exact);
  final p = _norm(pre);
  final q = _norm(post);
  if (e.isEmpty || t.length < e.length) return const [];
  bool eq(int a, List<String> b) {
    for (var i = 0; i < b.length; i++) {
      if (t[a + i] != b[i]) return false;
    }
    return true;
  }

  bool preOk(int at) {
    if (p.isEmpty) return true;
    var end = at;
    while (end > 0 && t[end - 1] == ' ') {
      end--;
    }
    if (end < p.length) return false;
    for (var i = 0; i < p.length; i++) {
      if (t[end - p.length + i] != p[i]) return false;
    }
    return true;
  }

  bool postOk(int at) {
    if (q.isEmpty) return true;
    var st = at + e.length;
    while (st < t.length && t[st] == ' ') {
      st++;
    }
    if (t.length - st < q.length) return false;
    for (var i = 0; i < q.length; i++) {
      if (t[st + i] != q[i]) return false;
    }
    return true;
  }

  // Карта нормализованный индекс → (начало, конец) в исходной строке:
  // строим повторно посимвольно (нормализация выше отдаёт только
  // символы, позиции считаем тем же проходом).
  final pos = <(int, int)>[];
  {
    var prevWs = true;
    final it = text.split('');
    var off = 0;
    for (final c in it) {
      final len = c.length;
      if (c.trim().isEmpty) {
        if (!prevWs) pos.add((off, off + len));
        prevWs = true;
      } else if (_alnum.hasMatch(c)) {
        pos.add((off, off + len));
        prevWs = false;
      }
      off += len;
    }
  }
  // pos совпадает по индексам с t (в т.ч. хвостовой пробел отсутствует
  // в t — обрежем карту под его длину).
  if (pos.length > t.length) pos.length = t.length;

  final out = <TextRange>[];
  for (var at = 0; at + e.length <= t.length; at++) {
    if (eq(at, e) && preOk(at) && postOk(at)) {
      out.add((s: pos[at].$1, e: pos[at + e.length - 1].$2));
    }
  }
  return out;
}
