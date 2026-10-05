import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../refs.dart';
import '../theme.dart';

/// Список сносок и параллельных мест главы.
class NotesSheet extends StatelessWidget {
  const NotesSheet({
    super.key,
    required this.notes,
    required this.selectedVerse,
    required this.controller,
    required this.onRef,
  });

  final List<({int verse, NoteSpanDoc note})> notes;
  final int? selectedVerse;
  final ScrollController controller;

  /// Тап по распознанной библейской ссылке в тексте сноски.
  final void Function(Ref) onRef;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (notes.isEmpty) {
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
      itemCount: notes.length,
      itemBuilder: (context, i) {
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
                  TextSpan(children: _noteSpans(n.text, p, onRef)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Разбить текст сноски на спаны: обычный текст + гиперссылки
/// «Быт 1:1» → onRef. Ссылки рисуем виджетом (тапабельным), текст — спанами.
List<InlineSpan> _noteSpans(String text, Palette p, void Function(Ref) onRef) {
  final refs = findRefs(text);
  if (refs.isEmpty) {
    return [TextSpan(text: text, style: _noteStyle(p))];
  }
  final out = <InlineSpan>[];
  var pos = 0;
  for (final m in refs) {
    if (m.start > pos) {
      out.add(
        TextSpan(text: text.substring(pos, m.start), style: _noteStyle(p)),
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
            style: _noteStyle(p).copyWith(
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
    out.add(TextSpan(text: text.substring(pos), style: _noteStyle(p)));
  }
  return out;
}

TextStyle _noteStyle(Palette p) =>
    TextStyle(fontSize: 13, color: p.ink, height: 1.4);
