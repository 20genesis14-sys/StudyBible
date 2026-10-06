/// Словарь произношения (ADR 0017): подмены применяются только
/// к тексту, уходящему в синтез, — показанный стих не меняется.
///
/// Источники:
/// - встроенный минимум [_baseline] — библейские имена и церковная
///   лексика с ударением (комбинирующий акцент U+0301); движок,
///   не знающий акцент, просто его отбрасывает — вреда нет;
/// - `pronounce.tsv` в папке голосового пакета:
///   `слово<TAB>замена`, строки с `#` — комментарии; записи файла
///   переопределяют одноимённые ключи базового словаря.
///
/// Подмена побуквенно целых слов (не подстрок): «Бог» не заденет
/// «Богослова». Слово → слово, регистр первой буквы сохраняется.
library;

import 'dart:io';

class PronounceDict {
  const PronounceDict._(this._rules);

  final Map<String, String> _rules;

  /// Базовые подмены (рус.): распространённые имена/термины,
  /// где синтезаторы часто ставят неверное ударение.
  static const Map<String, String> _baseline = {
    'иов': 'ио́в',
    'авессалом': 'авессало́м',
    'валаам': 'валаа́м',
    'валтазар': 'валтаза́р',
    'вифлеем': 'вифлее́м',
    'вирсавия': 'вирсави́я',
    'гавриил': 'гаврии́л',
    'гедеон': 'гедео́н',
    'есфирь': 'есфи́рь',
    'иезекииль': 'иезеки́иль',
    'иезавель': 'иезаве́ль',
    'иерихон': 'иерихо́н',
    'иоиль': 'иои́ль',
    'мардохей': 'мардохе́й',
    'мелхиседек': 'мелхиседе́к',
    'навуходоносор': 'навуходоно́сор',
    'назарет': 'назаре́т',
    'никодим': 'никоди́м',
    'осия': 'оси́я',
    'понтий': 'по́нтий',
    'силоам': 'силоа́м',
    'синай': 'сина́й',
    'фарисей': 'фарисе́й',
    'хананей': 'ханане́й',
    'евхаристия': 'евхари́стия',
  };

  /// Граница слова: буква/цифра/подчёркивание — «не слово».
  static final _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

  /// Словарь по умолчанию (только базовые подмены).
  static const base = PronounceDict._(_baseline);

  /// Базовый словарь + `pronounce.tsv` из [dir] (если файл есть).
  /// Файл: `слово<TAB>замена` по строке; `#` — комментарий.
  static PronounceDict merged(String? dir) {
    if (dir == null) return base;
    final f = File('$dir/pronounce.tsv');
    if (!f.existsSync()) return base;
    final rules = Map<String, String>.of(_baseline);
    for (final line in f.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final tab = t.indexOf('\t');
      if (tab <= 0) continue;
      final k = t.substring(0, tab).trim().toLowerCase();
      final v = t.substring(tab + 1).trim();
      if (k.isNotEmpty && v.isNotEmpty) rules[k] = v;
    }
    return PronounceDict._(rules);
  }

  /// Тестовый конструктор: чистый словарь без базовых записей.
  const PronounceDict.raw(Map<String, String> rules) : _rules = rules;

  /// Применить подмены к [text]. Замена — целых слов; если слово
  /// в тексте с заглавной, замена пишется с заглавной. Результат —
  /// только для синтеза, отображаемый текст не трогаем.
  String apply(String text) {
    if (_rules.isEmpty) return text;
    final re = RegExp(_rules.keys.map(RegExp.escape).join('|'),
        caseSensitive: false, unicode: true);
    return text.replaceAllMapped(re, (m) {
      final t = m.input;
      // Проверка границ слова вручную: \b в Dart не знает кириллицу.
      if (m.start > 0 &&
          _wordChar.hasMatch(String.fromCharCode(t.codeUnitAt(m.start - 1)))) {
        return m[0]!;
      }
      if (m.end < t.length &&
          _wordChar.hasMatch(String.fromCharCode(t.codeUnitAt(m.end)))) {
        return m[0]!;
      }
      final rep = _rules[m[0]!.toLowerCase()]!;
      final head = m[0]![0];
      // С заглавной буквы — с заглавной (с акцентом не путаем).
      return head != head.toLowerCase()
          ? rep[0].toUpperCase() + rep.substring(1)
          : rep;
    });
  }
}
