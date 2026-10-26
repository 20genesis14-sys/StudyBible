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
    this.openModule,
    this.fromVrs = '',
    this.onOpenModule,
    this.panelLoader,
    this.metaLoader,
  });

  final List<({int verse, NoteSpanDoc note})> notes;
  final int? selectedVerse;
  final ScrollController controller;

  /// Ленивая выборка второго яруса ссылок (`openbible-xrefs`):
  /// `Future<List<PanelRef>>` для всей открытой главы, фильтрация по
  /// стиху — в `_PanelRefs`. null — панельного слоя нет.
  final Future<List<PanelRef>> Function()? panelLoader;

  /// Ленивая выборка `xrefs_meta` главы (типы связей консенсусного
  /// слоя) — включает фильтр чипов у слойных x-записей; null — слой
  /// старый/нет.
  final Future<List<XrefMeta>> Function()? metaLoader;

  /// Модуль открытой главы — источник текстов параллельных мест
  /// по умолчанию; задан → у записи выбранного стиха раскрываются
  /// тексты ссылок (как в карточке по маркеру).
  final String? openModule;

  /// Версификация модуля-источника ссылок.
  final String fromVrs;

  /// Тап по тексту места → навигация в его переводе (координата
  /// уже конвертирована); без него — onRef по исходной ссылке.
  final void Function(Ref, String moduleId)? onOpenModule;

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
    final selKey = GlobalKey();
    var selBound = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = selKey.currentContext;
      if (selBound && ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 200),
        );
      }
    });
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
        if (sel) selBound = true;
        return Container(
          key: sel ? selKey : null,
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (n.kind == 'x' &&
                        n.attrs.contains('src="layer"') &&
                        metaLoader != null)
                      _LayerXrefs(
                        loader: metaLoader!,
                        verse: notes[i].verse,
                        onRef: onRef,
                        fallback: n.text,
                      )
                    else
                      Text.rich(
                        TextSpan(
                          children: _noteSpans(
                            _noteText(n),
                            p,
                            onRef,
                            scale: n.kind == 'x'
                                ? settings.xrefScale
                                : settings.footScale,
                          ),
                        ),
                      ),
                    if (sel && n.kind == 'x' && openModule != null)
                      _XrefTexts(
                        future: _noteTexts(
                          n,
                          fromVrs: fromVrs,
                          openModule: openModule!,
                        ),
                        onRef: onRef,
                        onOpenModule: onOpenModule,
                      ),
                    if (sel && n.kind == 'x' && panelLoader != null)
                      _PanelRefs(
                        loader: panelLoader!,
                        verse: notes[i].verse,
                        onRef: onRef,
                      ),
                    if (sel &&
                        n.kind == 'x' &&
                        n.attrs.contains('src="layer"') &&
                        metaLoader != null)
                      _LayerXrefs(
                        loader: metaLoader!,
                        verse: notes[i].verse,
                        onRef: onRef,
                        fallback: n.text,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Тексты параллельных мест записи выбранного стиха в боковой
/// панели (компактный вид карточки): подпись-ссылка + текст из
/// settings.xrefModule/открытого перевода; тап навигирует.
class _XrefTexts extends StatelessWidget {
  const _XrefTexts({
    required this.future,
    required this.onRef,
    this.onOpenModule,
  });
  final Future<NoteTextItems> future;
  final void Function(Ref) onRef;
  final void Function(Ref, String moduleId)? onOpenModule;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return FutureBuilder<NoteTextItems>(
      future: future,
      builder: (context, snap) {
        final items = snap.data;
        if (items == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: p.muted),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final it in items)
              if (it.text != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: GestureDetector(
                    onTap: () {
                      final open = onOpenModule;
                      if (open != null) {
                        open(it.nav, it.mid);
                      } else {
                        onRef(it.ref);
                      }
                    },
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${it.label} — ',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: p.accent,
                            ),
                          ),
                          TextSpan(
                            text: it.text!,
                            style: TextStyle(
                              fontSize: 13 * settings.xrefScale,
                              color: p.ink,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
          ],
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
/// координатам ('' — из [openModule], модуля открытой главы),
/// а [onOpenModule] (если задан) навигирует к конвертированному
/// месту в переводе, из которого показан текст.
void showNoteCard(
  BuildContext context, {
  required NoteSpanDoc note,
  required int verse,
  required void Function(Ref) onRef,
  required String openModule,
  String fromVrs = '',
  void Function(Ref, String moduleId)? onOpenModule,
  VoidCallback? onShowAll,
  Future<List<PanelRef>> Function()? panelLoader,
  Future<List<XrefMeta>> Function()? metaLoader,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _NoteCard(
      note: note,
      verse: verse,
      openModule: openModule,
      fromVrs: fromVrs,
      panelLoader: panelLoader,
      metaLoader: metaLoader,
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
/// (settings.xrefModule; '' — открытый [openModule]). Высота ~75 %
/// экрана.
class _NoteCard extends StatefulWidget {
  final NoteSpanDoc note;
  final int verse;
  final void Function(Ref) onRef;
  final String openModule;
  final String fromVrs;
  final void Function(Ref, String moduleId)? onOpenModule;
  final VoidCallback? onShowAll;
  final Future<List<PanelRef>> Function()? panelLoader;
  final Future<List<XrefMeta>> Function()? metaLoader;
  const _NoteCard({
    required this.note,
    required this.verse,
    required this.onRef,
    required this.openModule,
    this.fromVrs = '',
    this.onOpenModule,
    this.onShowAll,
    this.panelLoader,
    this.metaLoader,
  });

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

/// Карточка параллельных мест ОДНОГО стиха — мобильный пункт меню
/// стиха «Параллельные» (reader_chrome, `_openVerseCard`). Показывает
/// все x-группы стиха подряд — каждая как в карточке по маркеру
/// (чипы типов слойных записей, кликабельные ссылки, тексты мест
/// из выбранного перевода), а второй ярус («Ещё ссылки») — один
/// общий на стих внизу: слабые ссылки привязаны к стиху, а не к
/// группе, и дублировать раскрывашку в каждой группе незачем.
///
/// UX-решение: тап по «Параллельные» — запрос именно стиха, поэтому
/// на узком экране открывается стихо-центричная карточка, а не шторка
/// всех сносок главы (chapter sheet): та смешивает стихи и прячет
/// нужную группу в общем списке. Обзор главы остаётся за кнопкой
/// «Сноски» панели инструментов (там он и есть цель), а на широком
/// экране обе точки входа ведут в боковую панель (_openNotes).
///
/// Если у стиха нет x-групп — короткая строка-заглушка, но общий
/// второй ярус всё равно показывается (при [panelLoader] != null):
/// слабые ссылки бывают и без сильных групп.
void showVerseCard(
  BuildContext context, {
  required List<({int verse, NoteSpanDoc note})> notes,
  required int verse,
  required void Function(Ref) onRef,
  required String openModule,
  String fromVrs = '',
  void Function(Ref, String moduleId)? onOpenModule,
  Future<List<PanelRef>> Function()? panelLoader,
  Future<List<XrefMeta>> Function()? metaLoader,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _VerseCard(
      notes: notes,
      verse: verse,
      openModule: openModule,
      fromVrs: fromVrs,
      panelLoader: panelLoader,
      metaLoader: metaLoader,
      onOpenModule: onOpenModule == null
          ? null
          : (r, mid) {
              Navigator.of(ctx).pop();
              onOpenModule(r, mid);
            },
      onRef: (r) {
        Navigator.of(ctx).pop();
        onRef(r);
      },
    ),
  );
}

/// Тело карточки стиха: список всех x-групп стиха + общий второй
/// ярус. Та же геометрия, что у [_NoteCard] (высота по содержимому,
/// потолок 75 % экрана).
class _VerseCard extends StatelessWidget {
  final List<({int verse, NoteSpanDoc note})> notes;
  final int verse;
  final void Function(Ref) onRef;
  final String openModule;
  final String fromVrs;
  final void Function(Ref, String moduleId)? onOpenModule;
  final Future<List<PanelRef>> Function()? panelLoader;
  final Future<List<XrefMeta>> Function()? metaLoader;
  const _VerseCard({
    required this.notes,
    required this.verse,
    required this.onRef,
    required this.openModule,
    this.fromVrs = '',
    this.onOpenModule,
    this.panelLoader,
    this.metaLoader,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // X-группы стиха — в порядке следования в главе; сноски (kind
    // 'f') и чужие стихи в карточку не попадают.
    final groups = [
      for (final n in notes)
        if (n.verse == verse && n.note.kind == 'x') n.note,
    ];
    return SafeArea(
      // Высота по содержимому, потолок — 75 % экрана (как у карточки
      // записи): короткий стих не показывает пустую форму, длинный —
      // прокручивается.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (groups.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            tr(
                              'Параллельных мест у стиха нет',
                              'No cross-references for this verse',
                            ),
                            style: TextStyle(color: p.muted),
                          ),
                        ),
                      for (final (i, note) in groups.indexed) ...[
                        if (i > 0) Divider(height: 18, color: p.edge),
                        _NoteGroupView(
                          note: note,
                          verse: verse,
                          onRef: onRef,
                          openModule: openModule,
                          fromVrs: fromVrs,
                          onOpenModule: onOpenModule,
                          metaLoader: metaLoader,
                          // Второй ярус — один общий на стих (ниже).
                          showPanelRefs: false,
                        ),
                      ],
                      // Общий второй ярус — один на стих, даже без
                      // сильных групп: слабые ссылки есть без сильных.
                      if (panelLoader != null) ...[
                        Divider(height: 18, color: p.edge),
                        _PanelRefs(
                          loader: panelLoader!,
                          verse: verse,
                          onRef: onRef,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Одна строка списка параллельных мест карточки: [mid] — модуль,
/// из которого реально показан текст (основной путь или фоллбэк).
typedef NoteTextItems =
    List<({Ref ref, Ref nav, String label, String? text, String mid})>;

/// Кэш готовых/идущих загрузок текстов сносок: ключ — перевод,
/// версификация источника и сам текст сноски. Карточка и фоновый
/// прогрев делят один Future — повторный тап мгновенный.
final Map<String, Future<NoteTextItems>> _noteTextsCache = {};

/// Тексты ссылок сноски [note]: по умолчанию — из открытого перевода
/// [openModule], при выбранном settings.xrefModule — из него; без
/// целевой книги/главы — фоллбэк на основной перевод (mainModuleId).
Future<NoteTextItems> _noteTexts(
  NoteSpanDoc note, {
  required String fromVrs,
  required String openModule,
}) {
  final mid = settings.xrefModule.isEmpty ? openModule : settings.xrefModule;
  final fb = mainModuleId();
  return _noteTextsCache.putIfAbsent(
    // Язык и раскладка — в ключе: подписи ссылок локализуются.
    '$mid\x00$fb\x00$fromVrs\x00${settings.lang}\x00${settings.bookNames}\x00${note.text}',
    () => _loadNoteTexts(note, fromVrs, mid, fb),
  );
}

/// Фоновый прогрев главы (открытие главы → до тапа по маркеру):
/// ссылки всех сносок конвертируются и главы-мишени подгружаются
/// лениво, так что карточка потом открывается без лага.
void prefetchChapterNotes(
  ChapterDoc ch, {
  required String fromVrs,
  required String openModule,
}) {
  if (ch.notesPrefetchDone) return;
  ch.notesPrefetchDone = true;
  for (final b in ch.blocks) {
    for (final s in b.spans) {
      if (s is NoteSpanDoc) {
        unawaited(
          _noteTexts(s, fromVrs: fromVrs, openModule: openModule).catchError(
            (_) =>
                <
                  ({Ref ref, Ref nav, String label, String? text, String mid})
                >[],
          ),
        );
      }
    }
  }
}

/// Координаты ссылки [r] (в версификации модуля-источника [fromVrs])
/// в версификации перевода [m]: каждый стих диапазона конвертируется,
/// совпадения дедуплицируются. Стихи диапазона — параллельно.
Future<List<CvPoint>> _noteTargets(ModuleDoc m, Ref r, String fromVrs) async {
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
/// [mid] — основной перевод текстов, [fbMid] — фоллбэк, когда в [mid]
/// нет целевой книги/главы (текст не найден): тогда и навигация
/// `open(it.nav, it.mid)` идёт в модуль фоллбэка.
Future<NoteTextItems> _loadNoteTexts(
  NoteSpanDoc note,
  String fromVrs,
  String mid,
  String fbMid,
) async {
  final noteText = _noteText(note);
  final refs = findRefs(noteText);
  if (refs.isEmpty) return const [];
  final m = await loadModule(mid);
  ModuleDoc? fb;
  final seen = <String>{};
  final jobs =
      <Future<({Ref ref, Ref nav, String label, String? text, String mid})>>[];
  for (final rm in refs) {
    final r = rm.ref;
    if (!seen.add('${r.book}:${r.chapter}:${r.verse}-${r.verseEnd}')) {
      continue;
    }
    final label = noteText.substring(rm.start, rm.end);
    jobs.add(
      _noteTargets(m, r, fromVrs).then((targets) async {
        var t = targets.isEmpty ? null : await convertedVerseText(m, targets);
        var midUsed = mid;
        var navTargets = targets;
        if (t == null && fbMid != mid) {
          fb ??= await loadModule(fbMid);
          final fbTargets = await _noteTargets(fb!, r, fromVrs);
          if (fbTargets.isNotEmpty) {
            final fbText = await convertedVerseText(fb!, fbTargets);
            if (fbText != null) {
              t = fbText;
              midUsed = fbMid;
              navTargets = fbTargets;
            }
          }
        }
        final nav = navTargets.isEmpty
            ? r
            : Ref(
                navTargets.first.book,
                navTargets.first.chapter,
                navTargets.first.verse,
              );
        return (ref: r, nav: nav, label: label, text: t, mid: midUsed);
      }),
    );
  }
  return Future.wait(jobs);
}

class _NoteCardState extends State<_NoteCard> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      // Высота по содержимому, потолок — 75 % экрана: короткая
      // сноска не показывает пустую форму, длинная — прокручивается.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: _NoteGroupView(
                  note: widget.note,
                  verse: widget.verse,
                  onRef: widget.onRef,
                  openModule: widget.openModule,
                  fromVrs: widget.fromVrs,
                  onOpenModule: widget.onOpenModule,
                  panelLoader: widget.panelLoader,
                  metaLoader: widget.metaLoader,
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

/// Содержимое одной записи (x-группы или сноски) — общий тело
/// карточки записи ([_NoteCard]) и карточки стиха ([_VerseCard]):
/// заголовок (вид записи, стих, привязка к части), текст с
/// активными ссылками (у слойных x-записей — чипы типов
/// `_LayerXrefs`), опциональный второй ярус и тексты параллельных
/// мест из выбранного перевода (settings.xrefModule; '' — открытый
/// [openModule]).
class _NoteGroupView extends StatefulWidget {
  final NoteSpanDoc note;
  final int verse;
  final void Function(Ref) onRef;
  final String openModule;
  final String fromVrs;
  final void Function(Ref, String moduleId)? onOpenModule;
  final Future<List<PanelRef>> Function()? panelLoader;
  final Future<List<XrefMeta>> Function()? metaLoader;

  /// Второй ярус («Ещё ссылки») у этой записи: в карточке записи —
  /// да; в карточке стиха — нет (один общий внизу, [showVerseCard]).
  final bool showPanelRefs;

  const _NoteGroupView({
    required this.note,
    required this.verse,
    required this.onRef,
    required this.openModule,
    this.fromVrs = '',
    this.onOpenModule,
    this.panelLoader,
    this.metaLoader,
    this.showPanelRefs = true,
  });

  @override
  State<_NoteGroupView> createState() => _NoteGroupViewState();
}

class _NoteGroupViewState extends State<_NoteGroupView> {
  /// ref → текст стиха(ов) + навигационная цель; общий кэш с
  /// фоновым прогревом главы — обычно уже готово к моменту тапа.
  late final Future<NoteTextItems> _texts = _noteTexts(
    widget.note,
    fromVrs: widget.fromVrs,
    openModule: widget.openModule,
  );

  /// Перевод текстов параллельных мест берётся построчно из
  /// `it.mid` (основной путь или фоллбэк) — общего _mid больше нет.

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final note = widget.note;
    return Column(
      mainAxisSize: MainAxisSize.min,
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
        // Прокручиваемая часть: сам текст записи (со ссылками-
        // гиперссылками, масштаб footScale/xrefScale) и под ним —
        // тексты параллельных мест. Список небольшой — ссылки
        // дедуплицированы, поэтому обычная колонка внутри общего
        // скролла, а не вложенный ListView.
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (note.kind == 'x' &&
                    note.attrs.contains('src="layer"') &&
                    widget.metaLoader != null)
                  _LayerXrefs(
                    loader: widget.metaLoader!,
                    verse: widget.verse,
                    onRef: widget.onRef,
                    fallback: note.text,
                  )
                else
                  Text.rich(
                    TextSpan(
                      children: _noteSpans(
                        _noteText(note),
                        p,
                        widget.onRef,
                        scale: note.kind == 'x'
                            ? settings.xrefScale
                            : settings.footScale,
                      ),
                    ),
                  ),
                if (widget.showPanelRefs &&
                    note.kind == 'x' &&
                    widget.panelLoader != null)
                  _PanelRefs(
                    loader: widget.panelLoader!,
                    verse: widget.verse,
                    onRef: widget.onRef,
                  ),
                FutureBuilder(
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
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final it in items) ...[
                          Divider(height: 14, color: p.edge),
                          GestureDetector(
                            onTap: () {
                              final open = widget.onOpenModule;
                              if (open != null) {
                                open(it.nav, it.mid);
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
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Текст спана для показа: слойные x-ссылки (attrs `src="layer"`)
/// приходят с OSIS-именами книг — переписываем их именами по языку
/// интерфейса и раскладке «Названия книг» (ADR 0023).
String _noteText(NoteSpanDoc n) =>
    n.kind == 'x' && n.attrs.contains('src="layer"')
    ? localizeRefs(n.text, bookShort)
    : n.text;

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
    TextStyle(fontSize: 15 * scale, color: p.ink, height: 1.45);

/// Раскрываемая строка второго яруса параллельных мест
/// (`openbible-xrefs`, ADR 0023): ссылки слабого ранга
/// (односемейные тематические и им. рёбра) по требованию — слой
/// ленивый, файл читается только при первом тапе.
class _PanelRefs extends StatefulWidget {
  const _PanelRefs({
    required this.loader,
    required this.verse,
    required this.onRef,
  });

  /// Выборка панельных ссылок всей главы (из результата берём стих).
  final Future<List<PanelRef>> Function() loader;
  final int verse;
  final void Function(Ref) onRef;

  @override
  State<_PanelRefs> createState() => _PanelRefsState();
}

class _PanelRefsState extends State<_PanelRefs> {
  bool _open = false;
  Future<List<PanelRef>>? _fut;

  void _toggle() {
    _fut ??= widget.loader();
    setState(() => _open = !_open);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (!_open) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _toggle,
          icon: Icon(Icons.unfold_more, size: 15, color: p.muted),
          label: Text(
            tr('Ещё ссылки', 'More references'),
            style: TextStyle(fontSize: 12, color: p.muted),
          ),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(0, 28),
          ),
        ),
      );
    }
    return FutureBuilder<List<PanelRef>>(
      future: _fut,
      builder: (context, snap) {
        if (!snap.hasData) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: p.muted),
            ),
          );
        }
        final mine = snap.data!.where((r) => r.verse == widget.verse).toList();
        if (mine.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              tr('Дополнительных ссылок нет', 'No additional references'),
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: p.muted,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Divider(height: 14, color: p.edge),
            for (final r in mine)
              Text.rich(
                TextSpan(
                  children: _noteSpans(
                    localizeRefs(r.refs, bookShort),
                    p,
                    widget.onRef,
                    scale: settings.xrefScale,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Тело слойной x-записи (`src="layer"`) с фильтрацией по типу связи:
/// чипы kinds из `xrefs_meta` + цели стиха (кликабельны). Старый слой
/// без метаданных — фолбэк на сырой текст записи.
class _LayerXrefs extends StatefulWidget {
  const _LayerXrefs({
    required this.loader,
    required this.verse,
    required this.onRef,
    required this.fallback,
  });

  /// Выборка meta-целей главы (берём стих [verse]).
  final Future<List<XrefMeta>> Function() loader;
  final int verse;
  final void Function(Ref) onRef;
  final String fallback;

  @override
  State<_LayerXrefs> createState() => _LayerXrefsState();
}

class _LayerXrefsState extends State<_LayerXrefs> {
  late final Future<List<XrefMeta>> _fut = widget.loader();
  final Set<String> _on = {};

  String _kindLabel(String k) => switch (k) {
    'quote' => tr('цитата', 'quote'),
    'para' => tr('параллель', 'parallel'),
    'verbal' => tr('словесная', 'verbal'),
    'historical' => tr('имя/история', 'name/history'),
    'thematic' => tr('тема', 'theme'),
    'prophecy' => tr('пророчество', 'prophecy'),
    'typology' => tr('типология', 'typology'),
    'contrast' => tr('контраст', 'contrast'),
    _ => k,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return FutureBuilder<List<XrefMeta>>(
      future: _fut,
      builder: (context, snap) {
        final all = (snap.data ?? const <XrefMeta>[])
            .where((x) => x.verse == widget.verse)
            .toList();
        if (!snap.hasData || all.isEmpty) {
          return Text.rich(
            TextSpan(
              children: _noteSpans(
                localizeRefs(widget.fallback, bookShort),
                p,
                widget.onRef,
                scale: settings.xrefScale,
              ),
            ),
          );
        }
        final kinds = <String>{for (final x in all) ...x.kinds}.toList();
        final shown = _on.isEmpty
            ? all
            : all.where((x) => x.kinds.any(_on.contains)).toList();
        final text = shown.map((x) => x.label).join('; ');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 0,
              children: [
                for (final k in kinds)
                  FilterChip(
                    label: Text(_kindLabel(k)),
                    selected: _on.contains(k),
                    onSelected: (v) =>
                        setState(() => v ? _on.add(k) : _on.remove(k)),
                    visualDensity: VisualDensity.compact,
                    labelStyle: const TextStyle(fontSize: 11),
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
            Text.rich(
              TextSpan(
                children: _noteSpans(
                  localizeRefs(text, bookShort),
                  p,
                  widget.onRef,
                  scale: settings.xrefScale,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
