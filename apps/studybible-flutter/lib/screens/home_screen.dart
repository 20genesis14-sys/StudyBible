import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n.dart';

import 'package:flutter/services.dart' show rootBundle;

import '../data.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import 'bookmarks_screen.dart';
import 'history_screen.dart';
import 'modules_screen.dart';
import 'plan_screen.dart';
import 'reading_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import '../routes.dart';

/// «Стих дня»: дата → ссылка по расписанию ежедневника
/// (только ссылка; текст берётся из выбранного модуля).
class DailyVerse {
  DailyVerse(this.book, this.chapter, this.verse, this.ref);
  final String book;
  final int chapter;
  final int verse;
  final String ref;
}

/// Главный экран: продолжить чтение, стих дня, история,
/// быстрые инструменты, прогресс.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DailyVerse? _daily;
  String? _dailyText;
  String? _dailyModuleId;

  static Map<String, DailyVerse>? _schedule;

  /// Модуль для текста стиха дня: первый русский из установленных,
  /// иначе первый в списке.
  String get _moduleId =>
      kModules.keys.contains('russyn') ? 'russyn' : kModules.keys.first;

  @override
  void initState() {
    super.initState();
    _load();
    history.load();
  }

  Future<void> _load() async {
    _schedule ??= await _loadSchedule();
    final now = DateTime.now();
    final key =
        '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final d = _schedule![key];
    if (!mounted) return;
    setState(() => _daily = d);
    if (d == null) return;
    _dailyModuleId = _moduleId;
    final m = await loadModule(_dailyModuleId!);
    final ch = await m.ensureChapter(d.book, d.chapter);
    if (!mounted) return;
    setState(() => _dailyText = _verseText(ch, d.verse));
  }

  static Future<Map<String, DailyVerse>> _loadSchedule() async {
    try {
      final raw = await rootBundle.loadString('assets/data/daily.json');
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return j.map(
        (k, v) => MapEntry(
          k,
          DailyVerse(
            v['book'] as String,
            (v['chapter'] as num).toInt(),
            (v['verse'] as num).toInt(),
            v['ref'] as String,
          ),
        ),
      );
    } catch (_) {
      return const {};
    }
  }

  /// Плоский текст стиха v в главе (как в reading_screen).
  static String _verseText(ChapterDoc? ch, int v) {
    if (ch == null) return '';
    final buf = StringBuffer();
    var inside = false;
    for (final b in ch.blocks) {
      for (final s in b.spans) {
        if (s is VerseSpanDoc) {
          inside = s.verse == v;
        } else if (inside && s is TextSpanDoc) {
          buf.write(s.text);
        }
      }
    }
    return buf.toString().trim();
  }

  void _open(String book, int chapter, {int? verse, String? moduleId}) {
    Navigator.of(context).push(
      fastRoute(
        ReadingScreen(
          bookCode: book,
          chapter: chapter,
          verse: verse,
          moduleId: moduleId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ADR 0015, вариант А: поиск — поле вверху Главной,
          // настройки — шестерёнка здесь же.
          Row(
            children: [
              Expanded(child: _searchField(p)),
              IconButton(
                tooltip: tr('Настройки', 'Settings'),
                icon: Icon(Icons.settings_outlined, color: p.muted),
                onPressed: () => Navigator.of(
                  context,
                ).push(fastRoute(const SettingsScreen())),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _continueCard(p),
          const SizedBox(height: 12),
          _planCard(p),
          const SizedBox(height: 12),
          _dailyCard(p),
          const SizedBox(height: 12),
          _historyCard(p),
          const SizedBox(height: 12),
          _toolsCard(p),
          const SizedBox(height: 12),
          _progressCard(p),
        ],
      ),
    );
  }

  // ---------- «Продолжить чтение» ----------

  Widget _continueCard(Palette p) {
    return ListenableBuilder(
      listenable: progress,
      builder: (_, _) {
        final pos = progress.lastPosition;
        if (pos == null) {
          return _card(
            p,
            child: ListTile(
              leading: Icon(Icons.menu_book, color: p.accent),
              title: Text(tr('Начните чтение', 'Start reading')),
              subtitle: Text(
                tr(
                  'Выберите книгу на вкладке «Библия»',
                  'Choose a book on the Bible tab',
                ),
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ),
          );
        }
        final parts = pos.split(':');
        final book = parts[0];
        final ch = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1;
        return _card(
          p,
          onTap: () => _open(book, ch),
          child: ListTile(
            leading: Icon(Icons.play_circle_fill, size: 40, color: p.accent),
            title: Text(
              tr('Продолжить чтение', 'Continue reading'),
              style: TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              tr(
                '${kShortName[book] ?? book}, глава $ch',
                '${kShortName[book] ?? book}, chapter $ch',
              ),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            trailing: Icon(Icons.chevron_right, color: p.muted),
          ),
        );
      },
    );
  }

  /// Поле поиска вверху Главной — тап открывает экран поиска.
  Widget _searchField(Palette p) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () =>
          Navigator.of(context).push(fastRoute(const SearchScreen())),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.edge),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 18, color: p.muted),
            const SizedBox(width: 8),
            Text(
              tr('Поиск по тексту', 'Search the text'),
              style: TextStyle(fontSize: 14, color: p.muted),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- «Сегодня по плану» ----------

  /// Карточка дня плана чтения (ADR 0015). Пока — вход на экран
  /// плана; содержимое появится с экраном «План» (Блок 2).
  Widget _planCard(Palette p) {
    return _card(
      p,
      onTap: () =>
          Navigator.of(context).push(fastRoute(const PlanScreen(pushed: true))),
      child: ListTile(
        leading: Icon(Icons.event_note_outlined, size: 32, color: p.accent),
        title: Text(
          tr('Сегодня по плану', 'Today in the plan'),
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: Text(
          tr('План чтения', 'Reading plan'),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        trailing: Icon(Icons.chevron_right, color: p.muted),
      ),
    );
  }

  // ---------- «Стих дня» ----------

  Widget _dailyCard(Palette p) {
    final d = _daily;
    if (d == null) return const SizedBox.shrink();
    return _card(
      p,
      onTap: () =>
          _open(d.book, d.chapter, verse: d.verse, moduleId: _dailyModuleId),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wb_sunny_outlined, size: 16, color: p.accent),
                const SizedBox(width: 6),
                Text(
                  tr('Стих дня', 'Verse of the day'),
                  style: TextStyle(
                    fontSize: 13,
                    color: p.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_dailyText != null)
              Text(
                _dailyText!,
                style: const TextStyle(fontSize: 16, height: 1.5),
              ),
            const SizedBox(height: 8),
            Text(
              d.ref,
              style: TextStyle(color: p.accent, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- История ----------

  Widget _historyCard(Palette p) {
    return ListenableBuilder(
      listenable: history,
      builder: (_, _) {
        // «Недавно читали» — только главы (словарь/поиск идут
        // в полную историю, чипы книг тут неуместны).
        final items = history.items
            .where((e) => e.text == 'hist')
            .take(6)
            .toList();
        if (items.isEmpty) return const SizedBox.shrink();
        return _card(
          p,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr('Недавно читали', 'Recently read'),
                        style: TextStyle(
                          fontSize: 13,
                          color: p.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          Navigator.of(context)
                              .push(fastRoute(const HistoryScreen())),
                      child: Text(tr('Вся история', 'All history')),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final e in items)
                      ActionChip(
                        label: Text(
                          '${kShortName[e.book] ?? e.book} ${e.chapter}',
                        ),
                        onPressed: () => _open(
                          e.book,
                          e.chapter,
                          verse: e.verse > 0 ? e.verse : null,
                          moduleId: e.module,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- Быстрые инструменты ----------

  Widget _toolsCard(Palette p) {
    Widget tool(IconData icon, String label, Widget screen) => InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(fastRoute(screen)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: p.accent),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
    return _card(
      p,
      child: Row(
        children: [
          Expanded(
            child: tool(
              Icons.search,
              tr('Поиск', 'Search'),
              const SearchScreen(),
            ),
          ),
          Expanded(
            child: tool(
              Icons.book_outlined,
              tr('Модули', 'Modules'),
              const ModulesScreen(pushed: true),
            ),
          ),
          Expanded(
            child: tool(
              Icons.bookmark_outline,
              tr('Закладки', 'Bookmarks'),
              const BookmarksScreen(),
            ),
          ),
          Expanded(
            child: tool(
              Icons.history,
              tr('История', 'History'),
              const HistoryScreen(),
            ),
          ),
          Expanded(
            child: tool(
              Icons.event_note_outlined,
              tr('График', 'Plan'),
              const PlanScreen(pushed: true),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Прогресс ----------

  Widget _progressCard(Palette p) {
    const total = 1189; // глав в каноне 66 книг
    return ListenableBuilder(
      listenable: progress,
      builder: (_, _) {
        final done = progress.read.length;
        final pct = done / total;
        return _card(
          p,
          onTap: () =>
              Navigator.of(context)
                  .push(fastRoute(const PlanScreen(pushed: true))),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('График чтения', 'Reading plan'),
                  style: TextStyle(
                    fontSize: 13,
                    color: p.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct.clamp(0, 1),
                          minHeight: 8,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${(pct * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  tr(
                    'Прочитано $done из $total глав',
                    'Read $done of $total chapters',
                  ),
                  style: TextStyle(fontSize: 12, color: p.muted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _card(Palette p, {required Widget child, VoidCallback? onTap}) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: child),
    );
  }
}
