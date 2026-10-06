/// «План»: активный план чтения + карта прочитанного по группам.
///
/// Планы — JSON из assets/data/plans.json (lib/plans.dart), день →
/// список отрывков. Прогресс — из ReadProgress (userdata.db через
/// мост): день считается выполненным, когда все главы дня помечены.
/// Выбор плана и дата старта — в настройках (settings.activePlan,
/// settings.planStart).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../data.dart';
import '../plans.dart';
import '../state.dart';
import '../theme.dart';
import '../routes.dart';
import 'chapter_grid_screen.dart';
import 'reading_screen.dart';

class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key, this.pushed = false});

  /// true — экран открыт поверх другого (с главной): нужен AppBar
  /// с кнопкой «назад», иначе вернуться нечем.
  final bool pushed;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  /// Код книги → число глав (из модуля; до загрузки — нули).
  Map<String, int> _chapters = {};
  List<ReadingPlan> _plans = const [];

  @override
  void initState() {
    super.initState();
    loadModule(kModules.keys.first).then((m) {
      if (!mounted) return;
      setState(() => _chapters = {for (final b in m.books) b.code: b.chapters});
    });
    loadPlans().then((pl) {
      if (!mounted) return;
      setState(() => _plans = pl);
    });
  }

  int _totalChapters(Iterable<String> codes) =>
      codes.fold(0, (s, c) => s + (_chapters[c] ?? 0));

  int _readChapters(Iterable<String> codes) =>
      codes.fold(0, (s, c) => s + progress.readCount(c));

  ReadingPlan? get _activePlan {
    for (final pl in _plans) {
      if (pl.id == settings.activePlan) return pl;
    }
    return null;
  }

  /// День выполнен — все его главы помечены прочитанными.
  bool _dayDone(List<PlanReading> day) => day.every(
    (r) => _readingDone(r),
  );

  bool _readingDone(PlanReading r) {
    for (var c = r.from; c <= r.to; c++) {
      if (!progress.isRead(r.book, c)) return false;
    }
    return true;
  }

  /// Сколько глав плана уже прочитано (по уникальным главам плана).
  int _planReadChapters(ReadingPlan plan) {
    var n = 0;
    for (final d in plan.days) {
      for (final r in d) {
        for (var c = r.from; c <= r.to; c++) {
          if (progress.isRead(r.book, c)) n++;
        }
      }
    }
    return n;
  }

  /// Серия дней подряд, закрытых по плану, заканчивая сегодняшним
  /// (или вчерашним, если сегодняшний ещё не закрыт).
  int _streak(ReadingPlan plan, int todayIdx) {
    var i = todayIdx;
    if (i >= plan.days.length) i = plan.days.length - 1;
    if (i >= 0 && !_dayDone(plan.days[i])) i--;
    var n = 0;
    while (i >= 0 && _dayDone(plan.days[i])) {
      n++;
      i--;
    }
    return n;
  }

  /// Читаемая подпись отрывка: «Быт 1–3» / «Пс 22».
  String _readingTitle(PlanReading r) {
    final name = kShortName[r.book] ?? r.book;
    return r.from == r.to ? '$name ${r.from}' : '$name ${r.from}–${r.to}';
  }

  void _openReading(PlanReading r) {
    // Переходим на первую непрочитанную главу отрывка (или на начало).
    var ch = r.from;
    for (var c = r.from; c <= r.to; c++) {
      if (!progress.isRead(r.book, c)) {
        ch = c;
        break;
      }
      ch = c;
    }
    Navigator.of(context).push(
      fastRoute(ReadingScreen(bookCode: r.book, chapter: ch)),
    );
  }

  void _startPlan(ReadingPlan plan) {
    final now = DateTime.now();
    settings.update(() {
      settings.activePlan = plan.id;
      settings.planStart =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
    });
    setState(() {});
  }

  void _stopPlan() {
    settings.update(() {
      settings.activePlan = '';
      settings.planStart = '';
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: Listenable.merge([progress, notes]),
      builder: (context, _) {
        final body = ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_activePlan == null) _planPicker(p) else _activePlanView(p),
            const SizedBox(height: 20),
            _readMap(p),
          ],
        );
        if (!widget.pushed) return body;
        return Scaffold(
          appBar: AppBar(title: Text(tr('План чтения', 'Reading plan'))),
          body: body,
        );
      },
    );
  }

  // ---------- Выбор плана ----------

  Widget _planPicker(Palette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Планы чтения', 'Reading plans'),
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: p.ink,
          ),
        ),
        const SizedBox(height: 10),
        for (final pl in _plans) _planCard(p, pl),
        if (_plans.isEmpty)
          Text(
            tr('Загрузка планов…', 'Loading plans…'),
            style: TextStyle(color: p.muted),
          ),
      ],
    );
  }

  Widget _planCard(Palette p, ReadingPlan pl) {
    final isRu = tr('x', 'y') == 'x'; // язык из tr: ru → 'x'
    return Card(
      color: p.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.edge),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isRu ? pl.title : pl.titleEn,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tr(
                '${pl.days.length} дн. · ${pl.totalChapters} гл.',
                '${pl.days.length} days · ${pl.totalChapters} ch.',
              ),
              style: TextStyle(fontSize: 13, color: p.muted),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: p.onAccent,
                ),
                onPressed: () => _startPlan(pl),
                child: Text(tr('Начать', 'Start')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Активный план ----------

  Widget _activePlanView(Palette p) {
    final plan = _activePlan!;
    final isRu = tr('x', 'y') == 'x';
    final todayIdx = planTodayIndex(settings.planStart);
    final readCh = _planReadChapters(plan);
    final totalCh = plan.totalChapters;
    final pct = totalCh == 0 ? 0.0 : readCh / totalCh;
    final done = todayIdx >= plan.days.length;
    final streak = _streak(plan, todayIdx);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          color: p.card,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: p.edge),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Кольцо прогресса плана.
                    SizedBox(
                      width: 54,
                      height: 54,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: pct,
                            strokeWidth: 5,
                            color: p.accent,
                            backgroundColor: p.edge,
                          ),
                          Text(
                            '${(pct * 100).round()}%',
                            style: TextStyle(fontSize: 12, color: p.ink),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isRu ? plan.title : plan.titleEn,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: p.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            done
                                ? tr('План завершён 🎉', 'Plan completed 🎉')
                                : tr(
                                    'День ${math.min(todayIdx + 1, plan.days.length)} из ${plan.days.length} · $readCh/$totalCh гл.',
                                    'Day ${math.min(todayIdx + 1, plan.days.length)} of ${plan.days.length} · $readCh/$totalCh ch.',
                                  ),
                            style: TextStyle(fontSize: 13, color: p.muted),
                          ),
                          if (streak > 0) ...[
                            const SizedBox(height: 2),
                            Text(
                              tr(
                                'Серия: $streak дн. 🔥',
                                'Streak: $streak days 🔥',
                              ),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: p.accent,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Завершить план', 'Stop plan'),
                      icon: Icon(Icons.close, color: p.muted),
                      onPressed: _stopPlan,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _weekStrip(p, plan, todayIdx),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (!done && todayIdx >= 0) _todayCard(p, plan, todayIdx),
        if (todayIdx < 0)
          Text(
            tr('План начнётся завтра.', 'The plan starts tomorrow.'),
            style: TextStyle(color: p.muted),
          ),
        // Ближайшие дни после сегодняшнего.
        for (var i = todayIdx + 1;
            i < plan.days.length && i <= todayIdx + 3;
            i++)
          _dayRow(p, plan, i, muted: true),
        const SizedBox(height: 8),
        TextButton.icon(
          icon: const Icon(Icons.swap_horiz, size: 18),
          label: Text(tr('Сменить план', 'Change plan')),
          onPressed: _stopPlan,
        ),
      ],
    );
  }

  /// Полоска текущей недели: точки по дням плана (пн..вс).
  Widget _weekStrip(Palette p, ReadingPlan plan, int todayIdx) {
    final now = DateTime.now();
    const labels = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    const labelsEn = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
    final ru = tr('x', 'y') == 'x';
    return Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Column(
              children: [
                Text(
                  (ru ? labels : labelsEn)[i],
                  style: TextStyle(fontSize: 11, color: p.muted),
                ),
                const SizedBox(height: 4),
                Builder(
                  builder: (_) {
                    final dayIdx = todayIdx + (i - (now.weekday - 1));
                    final isToday = i == now.weekday - 1;
                    final ok =
                        dayIdx >= 0 &&
                        dayIdx < plan.days.length &&
                        _dayDone(plan.days[dayIdx]);
                    return Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ok ? p.accent : Colors.transparent,
                        border: Border.all(
                          color: isToday
                              ? p.accent
                              : p.muted.withValues(alpha: 0.5),
                          width: isToday ? 2 : 1,
                        ),
                      ),
                      child: ok
                          ? Icon(Icons.check, size: 14, color: p.onAccent)
                          : null,
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// «Сегодня»: список отрывков дня с пометками выполнения.
  Widget _todayCard(Palette p, ReadingPlan plan, int todayIdx) {
    final day = plan.days[todayIdx];
    return Card(
      color: p.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.accent),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('Сегодня', 'Today'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: p.accent,
              ),
            ),
            const SizedBox(height: 8),
            for (final r in day) _readingRow(p, r),
            const SizedBox(height: 4),
            if (!_dayDone(day))
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(
                    tr('Отметить день прочитанным', 'Mark day as read'),
                  ),
                  onPressed: () {
                    for (final r in day) {
                      for (var c = r.from; c <= r.to; c++) {
                        progress.markRead(r.book, c);
                      }
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _readingRow(Palette p, PlanReading r) {
    final done = _readingDone(r);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _openReading(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle : Icons.circle_outlined,
              size: 20,
              color: done ? p.accent : p.muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _readingTitle(r),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: done ? p.muted : p.ink,
                  decoration: done ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: p.muted),
          ],
        ),
      ),
    );
  }

  /// Строка будущего дня плана (приглушённая).
  Widget _dayRow(Palette p, ReadingPlan plan, int i, {bool muted = false}) {
    final titles = plan.days[i].map(_readingTitle).join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              tr('День ${i + 1}', 'Day ${i + 1}'),
              style: TextStyle(fontSize: 12, color: p.muted),
            ),
          ),
          Expanded(
            child: Text(
              titles,
              style: TextStyle(fontSize: 13, color: p.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Карта прочитанного ----------

  Widget _readMap(Palette p) {
    final groups = <BookGroup, List<String>>{};
    for (final e in kCatalog) {
      groups.putIfAbsent(e.$3, () => []).add(e.$1);
    }
    final allCodes = kCatalog.map((e) => e.$1);
    final total = _totalChapters(allCodes);
    final readAll = _readChapters(allCodes);
    final ot = groups.entries.take(5).expand((e) => e.value);
    final nt = groups.entries.skip(5).expand((e) => e.value);
    final readOt = _readChapters(ot), totalOt = _totalChapters(ot);
    final readNt = _readChapters(nt), totalNt = _totalChapters(nt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Карта прочитанного', 'Reading map'),
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: p.ink,
          ),
        ),
        const SizedBox(height: 10),
        _overallCard(p, readAll, total, readOt, totalOt, readNt, totalNt),
        const SizedBox(height: 16),
        for (final g in groups.entries) _groupSection(p, g),
      ],
    );
  }

  Widget _overallCard(
    Palette p,
    int read,
    int total,
    int rOt,
    int tOt,
    int rNt,
    int tNt,
  ) {
    final pct = total == 0 ? 0.0 : read / total;
    return Card(
      color: p.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.edge),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Вся Библия', 'Whole Bible'),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                ),
                Text(
                  '$read / $total',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: p.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 8,
                color: p.accent,
                backgroundColor: p.edge,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tr(
                '${(pct * 100).toStringAsFixed(1)}% глав прочитано',
                '${(pct * 100).toStringAsFixed(1)}% of chapters read',
              ),
              style: TextStyle(fontSize: 12, color: p.muted),
            ),
            const SizedBox(height: 12),
            _miniBar(
              p,
              tr('Еврейско-арамейские писания', 'Hebrew-Aramaic Scriptures'),
              rOt,
              tOt,
            ),
            const SizedBox(height: 6),
            _miniBar(
              p,
              tr(
                'Христианские греческие писания',
                'Christian Greek Scriptures',
              ),
              rNt,
              tNt,
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniBar(Palette p, String label, int read, int total) {
    final pct = total == 0 ? 0.0 : read / total;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: p.muted),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          flex: 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              color: p.accent.withValues(alpha: 0.7),
              backgroundColor: p.edge,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('$read/$total', style: TextStyle(fontSize: 11, color: p.muted)),
      ],
    );
  }

  Widget _groupSection(Palette p, MapEntry<BookGroup, List<String>> g) {
    final color = groupColor(g.key, appThemeOf(context));
    final read = _readChapters(g.value);
    final total = _totalChapters(g.value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  g.key.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: p.ink,
                  ),
                ),
              ),
              Text(
                '$read/$total',
                style: TextStyle(fontSize: 12, color: p.muted),
              ),
            ],
          ),
        ),
        for (final code in g.value) _bookRow(p, code, color),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _bookRow(Palette p, String code, Color color) {
    final total = _chapters[code] ?? 0;
    final read = progress.readCount(code);
    final pct = total == 0 ? 0.0 : read / total;
    final title = kShortName[code] ?? code;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () =>
          Navigator.of(context)
              .push(fastRoute(ChapterGridScreen(bookCode: code))),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Row(
          children: [
            SizedBox(
              width: 110,
              child: Text(
                title,
                style: TextStyle(fontSize: 13, color: p.ink),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 6,
                  color: color,
                  backgroundColor: p.edge,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              child: Text(
                pct >= 1 ? '✓ $read/$total' : '$read/$total',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: pct >= 1 ? FontWeight.w700 : FontWeight.w400,
                  color: pct >= 1 ? color : p.muted,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
