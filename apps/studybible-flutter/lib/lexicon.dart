/// Словарь Стронга: данные и доступ.
///
/// Источник: Open Scriptures (`openscriptures/strongs`) — иврит (OSIS XML)
/// и греческий (Ulrik Petersen XML). Содержимое — общественное достояние
/// (Strong, 1890/1894); сборка данных — CC-BY-SA, атрибуция указана в
/// настройках и карточках. Формат JSON см. tools/gen_strongs_json.py.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'lexicon_ru_stub.dart'
    if (dart.library.html) 'lexicon_ru_web.dart'
    if (dart.library.io) 'lexicon_ru_io.dart';

/// Одна статья словаря Стронга.
class LexiconEntry {
  final String lemma; // слово на языке оригинала
  final String xlit; // транслитерация
  final String pos; // часть речи / морфология (иврит)
  final String pron; // произношение (греч.)
  final List<String> defs; // пункты определения (иврит)
  final String deriv; // происхождение
  final String expl; // краткое определение
  final String kjv; // как переведено в KJV

  const LexiconEntry({
    this.lemma = '',
    this.xlit = '',
    this.pos = '',
    this.pron = '',
    this.defs = const [],
    this.deriv = '',
    this.expl = '',
    this.kjv = '',
  });

  factory LexiconEntry.fromJson(Map<String, dynamic> j) => LexiconEntry(
    lemma: j['lemma'] as String? ?? '',
    xlit: j['xlit'] as String? ?? '',
    pos: j['pos'] as String? ?? '',
    pron: j['pron'] as String? ?? '',
    defs: (j['defs'] as List? ?? []).cast<String>(),
    deriv: j['deriv'] as String? ?? '',
    expl: j['expl'] as String? ?? '',
    kjv: j['kjv'] as String? ?? '',
  );
}

Map<String, LexiconEntry>? _dict;
Future<Map<String, LexiconEntry>>? _loading;

/// Найден ли и наложен ли русский словарь Стронга (для атрибуции в UI).
bool lexiconHasRussian = false;

/// Загрузить словарь один раз (лениво, ~3.7 МБ JSON).
///
/// Английский (Open Scriptures, встроен в приложение) — основа.
/// Поверх него, если найден, накладывается русский словарь Стронга
/// (Ю. А. Цыганков, «Библия для всех», 2005 — пользовательские данные
/// в STUDYBIBLE_DATA/dictionaries/strongs_ru.json; в web — dicts/…):
/// русские определения заменяют английские, недостающие поля
/// (происхождение, KJV) остаются из английской статьи.
Future<Map<String, LexiconEntry>> lexicon() {
  if (_dict != null) return Future.value(_dict!);
  return _loading ??= () async {
    final raw = await rootBundle.loadString('assets/data/strongs.json');
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final d = j.map(
      (k, v) => MapEntry(k, LexiconEntry.fromJson(v as Map<String, dynamic>)),
    );
    final ru = await loadRussianLexiconJson();
    lexiconHasRussian = ru != null && ru.isNotEmpty;
    if (ru != null) {
      for (final e in ru.entries) {
        final base = d[e.key];
        final r = LexiconEntry.fromJson(e.value as Map<String, dynamic>);
        d[e.key] = LexiconEntry(
          lemma: r.lemma.isNotEmpty ? r.lemma : (base?.lemma ?? ''),
          xlit: r.xlit.isNotEmpty ? r.xlit : (base?.xlit ?? ''),
          pos: base?.pos ?? '',
          pron: r.pron.isNotEmpty ? r.pron : (base?.pron ?? ''),
          // у русской статьи defs — дубль expl; оставляем англ. пункты
          defs: base?.defs ?? const [],
          deriv: base?.deriv ?? '',
          expl: r.expl.isNotEmpty ? r.expl : (base?.expl ?? ''),
          kjv: r.kjv.isNotEmpty ? r.kjv : (base?.kjv ?? ''),
        );
      }
    }
    _dict = d;
    return _dict!;
  }();
}

/// Нормализация номера Стронга из текста модуля ('H3117', 'G3056',
/// допускает ведущие нули 'G03056').
String? normalizeStrong(String s) {
  final m = RegExp(r'^[HhGg](\d+)$').firstMatch(s.trim());
  if (m == null) return null;
  return '${s[0].toUpperCase()}${int.parse(m.group(1)!)}';
}

/// Поиск по словарю: номер, лемма или определение (подстрока).
/// Возвращает до [limit] записей, номера идут первыми.
List<MapEntry<String, LexiconEntry>> lexiconSearch(
  Map<String, LexiconEntry> d,
  String query, {
  int limit = 50,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final num = normalizeStrong(query);
  final out = <MapEntry<String, LexiconEntry>>[];
  if (num != null && d.containsKey(num)) {
    out.add(MapEntry(num, d[num]!));
  }
  for (final e in d.entries) {
    if (out.length >= limit) break;
    if (e.key == num) continue;
    if (e.value.lemma.toLowerCase().contains(q) ||
        e.value.xlit.toLowerCase().contains(q) ||
        e.value.expl.toLowerCase().contains(q) ||
        e.value.kjv.toLowerCase().contains(q)) {
      out.add(e);
    }
  }
  return out;
}
