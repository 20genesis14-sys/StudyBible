import 'package:flutter/material.dart';

import '../data.dart';
import '../l10n.dart';
import '../models.dart';
import '../refs.dart';
import '../state.dart';
import '../theme.dart';

/// Список сносок и параллельных мест главы.
class NotesSheet extends StatelessWidget {
  const NotesSheet({
    super.key,
    required this.notes,
    required this.selectedVerse,
    required this.controller,
    required this.onRef,
    this.variants = const [],
  });

  final List<({int verse, NoteSpanDoc note})> notes;
  final int? selectedVerse;
  final ScrollController controller;

  /// Варианты критического аппарата главы (ADR 0016).
  final List<VariantDoc> variants;

  /// Тап по распознанной библейской ссылке в тексте сноски.
  final void Function(Ref) onRef;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (notes.isEmpty && variants.isEmpty) {
      return Center(
        child: Text(
          tr('В этой главе нет сносок', 'No footnotes in this chapter'),
          style: TextStyle(color: p.muted),
        ),
      );
    }
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.all(16),
      itemCount: notes.length + (variants.isEmpty ? 0 : variants.length + 1),
      itemBuilder: (context, i) {
        // Секция аппарата — после сносок (ADR 0016).
        if (i >= notes.length) {
          final vi = i - notes.length - 1;
          if (vi < 0) {
            return Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                tr('Критический аппарат', 'Critical apparatus'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: p.muted,
                ),
              ),
            );
          }
          final v = variants[vi];
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    'ст.${v.verse} · слова ${v.tokenFrom}–${v.tokenTo}',
                    'v.${v.verse} · words ${v.tokenFrom}–${v.tokenTo}',
                  ),
                  style: TextStyle(
                    fontSize: 10,
                    color: p.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                for (final r in v.readings)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        r.text.isEmpty ? '—' : r.text,
                        if (r.isBase) tr('(осн.)', '(base)'),
                        if (r.witnesses.isNotEmpty) r.witnesses.join(' '),
                      ].join(' '),
                      style: TextStyle(
                        fontSize: 13,
                        color: p.ink,
                        fontWeight: r.isBase
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }
        final n = notes[i].note;
        final sel = selectedVerse != null && notes[i].verse == selectedVerse;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: sel ? p.accent.withValues(alpha: 0.08) : null,
            borderRadius: BorderRadius.circular(6),
            border: sel
                ? Border.all(color: p.accent.withValues(alpha: 0.35))
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  if (notes[i].verse > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        tr('ст.${notes[i].verse}', 'v.${notes[i].verse}'),
                        style: TextStyle(
                          fontSize: 10,
                          color: sel ? p.accent : p.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: n.kind == 'x'
                          ? p.accent.withValues(alpha: 0.12)
                          : p.muted.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      n.kind == 'x' ? '×' : (n.caller.isEmpty ? '*' : n.caller),
                      style: TextStyle(fontSize: 11, color: p.accent),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: _noteSpans(
                      n.text,
                      p,
                      onRef,
                      scale: n.kind == 'x'
                          ? settings.xrefScale
                          : settings.footScale,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Карточка одной сноски/параллельного места по тапу на маркер
/// (ADR 0015). Показывает текст с активными ссылками; кнопка
/// «Все сноски» открывает полный список главы.
void showNoteCard(
  BuildContext context, {
  required NoteSpanDoc note,
  required int verse,
  required void Function(Ref) onRef,
  VoidCallback? onShowAll,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _NoteCard(
      note: note,
      verse: verse,
      onRef: (r) {
        Navigator.of(ctx).pop();
        onRef(r);
      },
      onShowAll: onShowAll == null
          ? null
          : () {
              Navigator.of(ctx).pop();
              onShowAll();
            },
    ),
  );
}

/// Содержимое карточки: текст сноски с активными ссылками, а под
/// ним — тексты каждого параллельного места из выбранного перевода
/// (settings.xrefModule; '' — основной). Высота ~75 % экрана.
class _NoteCard extends StatefulWidget {
  final NoteSpanDoc note;
  final int verse;
  final void Function(Ref) onRef;
  final VoidCallback? onShowAll;
  const _NoteCard({
    required this.note,
    required this.verse,
    required this.onRef,
    this.onShowAll,
  });

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<_NoteCard> {
  /// ref → текст стиха(ов); null-элементы — не найдено в переводе.
  late final Future<List<({Ref ref, String label, String? text})>> _texts =
      _load();

  Future<List<({Ref ref, String label, String? text})>> _load() async {
    final refs = findRefs(widget.note.text);
    if (refs.isEmpty) return const [];
    final mid = settings.xrefModule.isEmpty
        ? mainModuleId()
        : settings.xrefModule;
    final m = await loadModule(mid);
    final out = <({Ref ref, String label, String? text})>[];
    final seen = <String>{};
    for (final rm in refs) {
      final r = rm.ref;
      final key = '${r.book}:${r.chapter}:${r.verse}-${r.verseEnd}';
      if (!seen.add(key)) continue;
      final label = widget.note.text.substring(rm.start, rm.end);
      final ch = await m.ensureChapter(r.book, r.chapter);
      final t = ch == null ? null : verseText(ch, r.verse, r.verseEnd);
      out.add((ref: r, label: label, text: t == null || t.isEmpty ? null : t));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final note = widget.note;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: note.kind == 'x'
                          ? p.accent.withValues(alpha: 0.14)
                          : p.muted.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      note.kind == 'x'
                          ? '°'
                          : (note.caller.isEmpty ? '•' : note.caller),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: p.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    note.kind == 'x'
                        ? tr('Параллельные места', 'Cross-references')
                        : tr('Сноска', 'Footnote'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.muted,
                    ),
                  ),
                  if (widget.verse > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      tr('· ст. ${widget.verse}', '· v. ${widget.verse}'),
                      style: TextStyle(fontSize: 13, color: p.muted),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              // Сам текст сноски — со ссылками-гиперссылками; размер —
              // отдельный масштаб (footScale/xrefScale) из настроек.
              Text.rich(
                TextSpan(
                  children: _noteSpans(
                    note.text,
                    p,
                    widget.onRef,
                    scale: note.kind == 'x'
                        ? settings.xrefScale
                        : settings.footScale,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Тексты параллельных мест.
              Expanded(
                child: FutureBuilder(
                  future: _texts,
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: p.muted,
                            ),
                          ),
                        ),
                      );
                    }
                    final items = snap.data!;
                    if (items.isEmpty) return const SizedBox.shrink();
                    return ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 14,
                        color: p.edge,
                      ),
                      itemBuilder: (context, i) {
                        final it = items[i];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onTap: () => widget.onRef(it.ref),
                              child: Text(
                                it.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: p.accent,
                                ),
                              ),
                            ),
                            if (it.text != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  it.text!,
                                  style: TextStyle(
                                    fontSize:
                                        14 *
                                        (note.kind == 'x'
                                            ? settings.xrefScale
                                            : settings.footScale),
                                    color: p.ink,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
              if (widget.onShowAll != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: widget.onShowAll,
                    child: Text(tr('Все сноски главы', 'All chapter notes')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Разбить текст сноски на спаны: обычный текст + гиперссылки
/// «Быт 1:1» → onRef. Ссылки рисуем виджетом (тапабельным), текст — спанами.
List<InlineSpan> _noteSpans(
  String text,
  Palette p,
  void Function(Ref) onRef, {
  double scale = 1,
}) {
  final refs = findRefs(text);
  if (refs.isEmpty) {
    return [TextSpan(text: text, style: _noteStyle(p, scale))];
  }
  final out = <InlineSpan>[];
  var pos = 0;
  for (final m in refs) {
    if (m.start > pos) {
      out.add(
        TextSpan(
          text: text.substring(pos, m.start),
          style: _noteStyle(p, scale),
        ),
      );
    }
    final shown = text.substring(m.start, m.end);
    out.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => onRef(m.ref),
          child: Text(
            shown,
            style: _noteStyle(p, scale).copyWith(
              color: p.accent,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationColor: p.accent.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
    pos = m.end;
  }
  if (pos < text.length) {
    out.add(TextSpan(text: text.substring(pos), style: _noteStyle(p, scale)));
  }
  return out;
}

TextStyle _noteStyle(Palette p, [double scale = 1]) =>
    TextStyle(fontSize: 14 * scale, color: p.ink, height: 1.4);
