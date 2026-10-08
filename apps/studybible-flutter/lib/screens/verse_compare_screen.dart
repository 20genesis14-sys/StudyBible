/// «Стих во всех переводах»: одна строка на модуль — название,
/// текст стиха, переход к нему в этом переводе. Список модулей —
/// настройка settings.compareModules (пусто = все установленные).
///
/// Сопоставление стихов — через версификации (вопрос 8): координата
/// исходного модуля (fromVrs) переводится в версификацию каждого
/// перевода; несколько соответствий перечисляются с номерами
/// «глава:стих», переход по тапу — на первую координату.
library;

import 'package:flutter/material.dart';

import '../data.dart';
import '../l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../routes.dart';
import '../vrs.dart';
import 'reading_screen.dart';

class VerseCompareScreen extends StatefulWidget {
  const VerseCompareScreen({
    super.key,
    required this.bookCode,
    required this.chapter,
    required this.verse,
    this.fromVrs = '',
    this.onBack,
    this.onOpenVerse,
  });

  final String bookCode;
  final int chapter;
  final int verse;

  /// Версификация модуля, из которого открыли сравнение
  /// ('' — координату трактуем как есть, без конверсии).
  final String fromVrs;

  /// Встроенный режим (экран-позиция рабочего места): «назад» и тап
  /// по переводу идут через стек читалки, а не через Navigator.
  final VoidCallback? onBack;
  final OpenVerse? onOpenVerse;

  @override
  State<VerseCompareScreen> createState() => _VerseCompareScreenState();
}

class _Row {
  final String moduleId, title;
  String? text; // null — стиха нет в этом переводе / модуль без главы
  /// Куда ведёт тап: первая конвертированная координата (глава и
  /// даже книга могут отличаться от исходной).
  String navBook;
  int navChapter, navVerse;
  _Row(
    this.moduleId,
    this.title,
    this.text,
    this.navBook,
    this.navChapter,
    this.navVerse,
  );
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
        // Исходная координата — в версификации основного модуля;
        // в версификацию этого перевода — через конверсию.
        final targets = widget.fromVrs.isEmpty || m.versification.isEmpty
            ? [
                (
                  book: widget.bookCode,
                  chapter: widget.chapter,
                  verse: widget.verse,
                ),
              ]
            : await convertVerse(
                widget.bookCode,
                widget.chapter,
                widget.verse,
                widget.fromVrs,
                m.versification,
              );
        final t = targets.isEmpty
            ? null
            : await convertedVerseText(m, targets);
        final nav = targets.isEmpty
            ? (
                book: widget.bookCode,
                chapter: widget.chapter,
                verse: widget.verse,
              )
            : targets.first;
        rows.add(
          _Row(
            id,
            moduleName(id),
            t,
            nav.book,
            nav.chapter,
            nav.verse,
          ),
        );
      } catch (_) {
        rows.add(
          _Row(
            id,
            moduleName(id),
            null,
            widget.bookCode,
            widget.chapter,
            widget.verse,
          ),
        );
      }
      if (mounted) setState(() => _rows = List.of(rows));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ref = '${bookShort(widget.bookCode)} '
        '${widget.chapter}:${widget.verse}';
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        leading: widget.onBack == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              ),
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
                    onTap: widget.onOpenVerse != null
                        ? () => widget.onOpenVerse!(
                            r.moduleId, r.navBook, r.navChapter, r.navVerse)
                        : () => Navigator.of(context).push(
                            fastRoute(
                              ReadingScreen(
                                bookCode: r.navBook,
                                chapter: r.navChapter,
                                verse: r.navVerse,
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
                            r.text ?? tr('— нет в этом переводе',
                                '— not in this translation'),
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
