/// Планы чтения — данные из assets/data/plans.json (ADR 0015).
///
/// План — список дней; день — список отрывков (книга, главы f..t).
/// «Хронологический» собран по графику sbr_U.pdf (366 дней, вся
/// Библия за год); «Евангелия» — Мф+Мк+Лк+Ин, 89 глав за 30 дней.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Один отрывок дня: книга [book], главы [from]..[to] включительно.
class PlanReading {
  final String book;
  final int from, to;
  const PlanReading(this.book, this.from, this.to);

  int get chapters => to - from + 1;
}

/// План чтения: [days] — последовательные дни.
class ReadingPlan {
  final String id;
  final String title, titleEn;
  final List<List<PlanReading>> days;
  const ReadingPlan(this.id, this.title, this.titleEn, this.days);

  /// Всего глав в плане.
  int get totalChapters =>
      days.fold(0, (s, d) => s + d.fold(0, (x, r) => x + r.chapters));
}

List<ReadingPlan>? _cache;

/// Загрузить планы из assets (кэшируется).
Future<List<ReadingPlan>> loadPlans() async {
  if (_cache != null) return _cache!;
  try {
    final raw = await rootBundle.loadString('assets/data/plans.json');
    final j = jsonDecode(raw) as Map<String, dynamic>;
    _cache = [
      for (final p in (j['plans'] as List))
        ReadingPlan(
          p['id'] as String,
          p['title'] as String,
          p['titleEn'] as String? ?? p['title'] as String,
          [
            for (final d in (p['days'] as List))
              [
                for (final r in (d as List))
                  PlanReading(
                    r['b'] as String,
                    r['f'] as int,
                    r['t'] as int,
                  ),
              ],
          ],
        ),
    ];
  } catch (_) {
    _cache = const [];
  }
  return _cache!;
}

/// День плана по дате старта: индекс дня, который «по календарю»
/// соответствует сегодняшнему дню (может выйти за пределы плана).
int planTodayIndex(String planStart) {
  // Строгая проверка: DateTime.tryParse нормализует переполненные
  // даты ('2026-13-45' → январь 2027), что даст ложный отрицательный
  // индекс. Требуем ровно yyyy-mm-dd и roundtrip.
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(planStart)) return -1;
  // Формат гарантирован — parse не может вернуть null здесь.
  final s = DateTime.parse(planStart);
  final back =
      '${s.year.toString().padLeft(4, '0')}-'
      '${s.month.toString().padLeft(2, '0')}-'
      '${s.day.toString().padLeft(2, '0')}';
  if (back != planStart) return -1;
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day)
      .difference(DateTime(s.year, s.month, s.day))
      .inDays;
}
