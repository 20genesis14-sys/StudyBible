import 'dart:async';

import 'package:flutter/material.dart';

import '../data.dart';
import '../l10n.dart';
import '../models.dart';
import '../refs.dart';
import '../state.dart';
import '../theme.dart';
import '../vrs.dart';

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
                        tr(
                          'ст.${notes[i].verse}${n.part ?? ''}',
                          'v.${notes[i].verse}${n.part ?? ''}',
                        ),
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
///
/// [fromVrs] — версификация модуля-источника ссылки (в ней
/// записаны координаты в тексте сноски); тексты параллельных
/// мест берутся из settings.xrefModule по конвертированным
/// координатам, а [onOpenModule] (если задан) навигирует к
/// конвертированному месту в этом же переводе.
void showNoteCard(
  BuildContext context, {
  required NoteSpanDoc note,
  required int verse,
  required void Function(Ref) onRef,
  String fromVrs = '',
  void Function(Ref, String moduleId)? onOpenModule,
  VoidCallback? onShowAll,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _NoteCard(
      note: note,
      verse: verse,
      fromVrs: fromVrs,
      onOpenModule: (r, mid) {
        Navigator.of(ctx).pop();
        onOpenModule!(r, mid);
      },
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
  final String fromVrs;
  final void Function(Ref, String moduleId)? onOpenModule;
  final VoidCallback? onShowAll;
  const _NoteCard({
    required this.note,
    required this.verse,
    required this.onRef,
    this.fromVrs = '',
    this.onOpenModule,
    this.onShowAll,
  });

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

/// Одна строка списка параллельных мест карточки.
typedef NoteTextItems =
    List<({Ref ref, Ref nav, String label, String? text})>;

/// Кэш готовых/идущих загрузок текстов сносок: ключ — перевод,
/// версификация источника и сам текст сноски. Карточка и фоновый
/// прогрев делят один Future — повторный тап мгновенный.
final Map<String, Future<NoteTextItems>> _noteTextsCache = {};

/// Тексты ссылок сноски [note] из перевода xrefModule (или основного).
Future<NoteTextItems> _noteTexts(
  NoteSpanDoc note, {
  required String fromVrs,
}) {
  final mid = settings.xrefModule.isEmpty
      ? mainModuleId()
      : settings.xrefModule;
  return _noteTextsCache.putIfAbsent(
    '$mid\x00$fromVrs\x00${note.text}',
    () => _loadNoteTexts(note, fromVrs, mid),
  );
}

/// Фоновый прогрев главы (открытие главы → до тапа по маркеру):
/// ссылки всех сносок конвертируются и главы-мишени подгружаются
/// лениво, так что карточка потом открывается без лага.
void prefetchChapterNotes(ChapterDoc ch, {required String fromVrs}) {
  if (ch.notesPrefetchDone) return;
  ch.notesPrefetchDone = true;
  for (final b in ch.blocks) {
    for (final s in b.spans) {
      if (s is NoteSpanDoc) {
        unawaited(
          _noteTexts(s, fromVrs: fromVrs).catchError(
            (_) => <({Ref ref, Ref nav, String label, String? text})>[],
          ),
        );
      }
    }
  }
}

/// Координаты ссылки [r] (в версификации модуля-источника [fromVrs])
/// в версификации перевода [m]: каждый стих диапазона конвертируется,
/// совпадения дедуплицируются. Стихи диапазона — параллельно.
Future<List<CvPoint>> _noteTargets(
  ModuleDoc m,
  Ref r,
  String fromVrs,
) async {
  final perVerse = <Future<List<CvPoint>>>[
    for (var v = r.verse; v <= r.verseEnd; v++)
      fromVrs.isEmpty || m.versification.isEmpty
          ? Future.value([(book: r.book, chapter: r.chapter, verse: v)])
          : convertVerse(r.book, r.chapter, v, fromVrs, m.versification),
  ];
  final out = <CvPoint>[];
  final seen = <String>{};
  for (final pts in await Future.wait(perVerse)) {
    for (final p in pts) {
      if (seen.add('${p.book}:${p.chapter}:${p.verse}')) out.add(p);
    }
  }
  return out;
}

/// Загрузка текстов всех ссылок сноски: ссылки дедуплицируются
/// и обрабатываются параллельно — последовательная цепочка await
/// на десяток ссылок давала ощутимый лаг карточки.
Future<NoteTextItems> _loadNoteTexts(
  NoteSpanDoc note,
  String fromVrs,
  String mid,
) async {
  final refs = findRefs(note.text);
  if (refs.isEmpty) return const [];
  final m = await loadModule(mid);
  final seen = <String>{};
  final jobs = <Future<({Ref ref, Ref nav, String label, String? text})>>[];
  for (final rm in refs) {
    final r = rm.ref;
    if (!seen.add('${r.book}:${r.chapter}:${r.verse}-${r.verseEnd}')) {
      continue;
    }
    final label = note.text.substring(rm.start, rm.end);
    jobs.add(
      _noteTargets(m, r, fromVrs).then((targets) async {
        final t = targets.isEmpty
            ? null
            : await convertedVerseText(m, targets);
        final nav = targets.isEmpty
            ? r
            : Ref(
                targets.first.book,
                targets.first.chapter,
                targets.first.verse,
              );
        return (ref: r, nav: nav, label: label, text: t);
      }),
    );
  }
  return Future.wait(jobs);
}

class _NoteCardState extends State<_NoteCard> {
  /// ref → текст стиха(ов) + навигационная цель; общий кэш с
  /// фоновым прогревом главы — обычно уже готово к моменту тапа.
  late final Future<NoteTextItems> _texts = _noteTexts(
    widget.note,
    fromVrs: widget.fromVrs,
  );

  /// Перевод текстов параллельных мест (xrefModule или основной).
  String get _mid => settings.xrefModule.isEmpty
      ? mainModuleId()
      : settings.xrefModule;

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
                      tr(
                        '· ст. ${widget.verse}${note.part ?? ''}',
                        '· v. ${widget.verse}${note.part ?? ''}',
                      ),
                      style: TextStyle(fontSize: 13, color: p.muted),
                    ),
                  ],
                  // Цитата привязки к части стиха (ADR 0016, п. 8).
                  if (note.anchor != null && note.anchor!.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        tr('· «${note.anchor}»', '· “${note.anchor}”'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                          color: p.muted,
                        ),
                      ),
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
                              onTap: () {
                                final open = widget.onOpenModule;
                                if (open != null) {
                                  open(it.nav, _mid);
                                } else {
                                  widget.onRef(it.ref);
                                }
                              },
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
