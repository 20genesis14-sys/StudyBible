/// «Стих во всех переводах»: одна строка на модуль — название,
/// текст стиха, переход к нему в этом переводе. Список модулей —
/// настройка settings.compareModules (пусто = все установленные).
library;

import 'package:flutter/material.dart';

import '../data.dart';
import '../l10n.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../routes.dart';
import 'reading_screen.dart';

class VerseCompareScreen extends StatefulWidget {
  const VerseCompareScreen({
    super.key,
    required this.bookCode,
    required this.chapter,
    required this.verse,
  });

  final String bookCode;
  final int chapter;
  final int verse;

  @override
  State<VerseCompareScreen> createState() => _VerseCompareScreenState();
}

class _Row {
  final String moduleId, title;
  String? text; // null — стиха нет в этом переводе / модуль без главы
  _Row(this.moduleId, this.title, this.text);
}

class _VerseCompareScreenState extends State<VerseCompareScreen> {
  List<_Row> _rows = const [];
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = <_Row>[];
    for (final id in settings.compareList) {
      try {
        final m = await loadModule(id);
        final ch = await m.ensureChapter(widget.bookCode, widget.chapter);
        final t = ch == null
            ? null
            : verseText(ch, widget.verse).trim();
        rows.add(_Row(id, kModules[id] ?? id,
            t == null || t.isEmpty ? null : t));
      } catch (_) {
        rows.add(_Row(id, kModules[id] ?? id, null));
      }
      if (mounted) setState(() => _rows = List.of(rows));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ref = '${kShortName[widget.bookCode] ?? widget.bookCode} '
        '${widget.chapter}:${widget.verse}';
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.background,
        iconTheme: IconThemeData(color: p.ink),
        title: Text(
          tr('$ref — все переводы', '$ref — all translations'),
          style: TextStyle(color: p.ink, fontSize: 16),
        ),
      ),
      body: _rows.isEmpty && _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _rows.length + (_busy ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                if (i >= _rows.length) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final r = _rows[i];
                return Card(
                  color: p.card,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: p.edge),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => Navigator.of(context).push(
                      fastRoute(
                        ReadingScreen(
                          bookCode: widget.bookCode,
                          chapter: widget.chapter,
                          verse: widget.verse,
                          moduleId: r.moduleId,
                        ),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  r.title,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: p.accent,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.chevron_right,
                                size: 18,
                                color: p.muted,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            r.text ?? tr('— нет этого стиха', '— no this verse'),
                            style: TextStyle(
                              fontSize: 14,
                              color: r.text == null ? p.muted : p.ink,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
