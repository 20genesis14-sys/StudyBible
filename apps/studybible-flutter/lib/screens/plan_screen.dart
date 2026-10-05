/// «График чтения»: наглядный прогресс по группам и книгам + заметки.
///
/// Прочитанные главы — из ReadProgress (персистируется через мост в
/// userdata.db). Всего глав по каждой книге — из первого загруженного
/// модуля (каталог глав одинаков у всех модулей канона).
library;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../data.dart';
import '../state.dart';
import '../theme.dart';
import 'chapter_grid_screen.dart';
import '../routes.dart';

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
  final _noteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    loadModule(kModules.keys.first).then((m) {
      if (!mounted) return;
      setState(() => _chapters = {for (final b in m.books) b.code: b.chapters});
    });
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  int _totalChapters(Iterable<String> codes) =>
      codes.fold(0, (s, c) => s + (_chapters[c] ?? 0));

  int _readChapters(Iterable<String> codes) =>
      codes.fold(0, (s, c) => s + progress.readCount(c));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: Listenable.merge([progress, notes]),
      builder: (context, _) {
        final groups = <BookGroup, List<String>>{};
        for (final e in kCatalog) {
          groups.putIfAbsent(e.$3, () => []).add(e.$1);
        }
        final allCodes = kCatalog.map((e) => e.$1);
        final total = _totalChapters(allCodes);
        final readAll = _readChapters(allCodes);
        // Группы ВЗ — первые 5, НЗ — остальные.
        final ot = groups.entries.take(5).expand((e) => e.value);
        final nt = groups.entries.skip(5).expand((e) => e.value);
        final readOt = _readChapters(ot), totalOt = _totalChapters(ot);
        final readNt = _readChapters(nt), totalNt = _totalChapters(nt);

        final body = ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _overallCard(p, readAll, total, readOt, totalOt, readNt, totalNt),
            const SizedBox(height: 20),
            for (final g in groups.entries) _groupSection(p, g),
            const SizedBox(height: 20),
            _notesCard(p),
          ],
        );
        if (!widget.pushed) return body;
        return Scaffold(
          appBar: AppBar(title: Text(tr('График чтения', 'Reading plan'))),
          body: body,
        );
      },
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

  Widget _notesCard(Palette p) {
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
              tr('Заметки', 'Notes'),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _noteCtrl,
                    maxLines: 3,
                    minLines: 1,
                    style: TextStyle(fontSize: 14, color: p.ink),
                    decoration: InputDecoration(
                      hintText: tr('Новая заметка…', 'New note…'),
                      hintStyle: TextStyle(color: p.muted),
                      filled: true,
                      fillColor: p.background,
                      contentPadding: const EdgeInsets.all(10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: p.edge),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: p.edge),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: p.accent),
                  icon: Icon(Icons.add, color: p.onAccent),
                  onPressed: () {
                    notes.add(_noteCtrl.text);
                    _noteCtrl.clear();
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (notes.items.isEmpty)
              Text(
                tr(
                  'Заметок пока нет — они сохранятся при подключении пользовательской базы.',
                  'No notes yet — they will persist once the user database is connected.',
                ),
                style: TextStyle(fontSize: 12, color: p.muted),
              ),
            for (final n in notes.items)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: p.background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.edge),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        n.text,
                        style: TextStyle(
                          fontSize: 13,
                          color: p.ink,
                          height: 1.35,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close, size: 16, color: p.muted),
                      onPressed: () => notes.remove(n),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
