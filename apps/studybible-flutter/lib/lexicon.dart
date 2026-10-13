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
    if (dart.library.js_interop) 'lexicon_ru_web.dart'
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

/// Сбросить кэш словаря (после импорта strongs_ru.json): следующий
/// вызов lexicon() пересоберёт словарь с русским оверлеем.
void lexiconReset() {
  _dict = null;
  _loading = null;
  lexiconHasRussian = false;
}

/// Нормализация номера Стронга из текста модуля.
///
/// - 'H3117', 'G3056', ведущие нули 'G03056' → 'G3056';
/// - уточнённый номер с буквой 'H0029G' → 'H0029G' (dStrong, ADR 0025);
/// - unfoldingWord 'G15100' (классический номер + добивка нулём до
///   5 знаков) → 'G1510';
/// - список через пробел 'H1254 H853' → нормализуется каждый номер.
///
/// Двусмысленность uW-добивки (подлинный dStrong вида 'G21370'
/// тоже кончается нулём) снимается вызывающим: сначала ищется исходная
/// строка, потом нормализованная.
String? normalizeStrong(String s) {
  final parts = s.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty) return null;
  final out = <String>[];
  for (final p in parts) {
    final n = _normStrongOne(p);
    if (n == null) return null;
    out.add(n);
  }
  return out.join(' ');
}

String? _normStrongOne(String s) {
  final m = RegExp(r'^([HhGg])(\d+)([A-Za-z])?$').firstMatch(s);
  if (m == null) return null;
  final letter = m.group(1)!.toUpperCase();
  final digits = m.group(2)!;
  final suffix = m.group(3)?.toUpperCase() ?? '';
  if (suffix.isNotEmpty) {
    // dStrong с буквой значения: канон — 4 знака + буква ('H29G' → 'H0029G').
    return '$letter${digits.padLeft(4, '0')}$suffix';
  }
  var num = int.parse(digits);
  if (digits.length == 5 && digits.endsWith('0')) {
    num = int.parse(digits.substring(0, 4)); // uW-добивка
  }
  return '$letter$num';
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
  // Точный ключ важнее нормализации: подлинный dStrong 'G21370' не
  // должен подменяться uW-интерпретацией 'G2137'.
  final raw = query.trim().toUpperCase();
  if (d.containsKey(raw)) {
    out.add(MapEntry(raw, d[raw]!));
  } else if (num != null && d.containsKey(num)) {
    out.add(MapEntry(num, d[num]!));
  }
  for (final e in d.entries) {
    if (out.length >= limit) break;
    if (e.key == num || e.key == raw) continue;
    if (e.value.lemma.toLowerCase().contains(q) ||
        e.value.xlit.toLowerCase().contains(q) ||
        e.value.expl.toLowerCase().contains(q) ||
        e.value.kjv.toLowerCase().contains(q)) {
      out.add(e);
    }
  }
  return out;
}
