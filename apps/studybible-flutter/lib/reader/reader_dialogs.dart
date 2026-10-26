import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../attachments_stub.dart'
    if (dart.library.io) '../attachments_io.dart'
    if (dart.library.js_interop) '../attachments_web.dart';
import '../l10n.dart';
import '../lexicon.dart';
import '../state.dart' show splitNote, joinNote;
import '../native_bridge.dart' show UserEntry;
import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.js_interop) '../native_bridge_web.dart';
import '../theme.dart';
import '../userdata_bus.dart';

/// Диалог тегов стиха: контроллер живёт в State. Если dispose()
/// вызывать снаружи сразу после await showDialog, он срабатывал до
/// конца разборки route — TextField успевал пересоздать зависимость
/// от стилей внутри route и движок ронял '_dependents.isEmpty'.
class TagsDialog extends StatefulWidget {
  const TagsDialog({super.key, required this.ref, required this.initial});

  final String ref, initial;

  @override
  State<TagsDialog> createState() => _TagsDialogState();
}

class _TagsDialogState extends State<TagsDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _close([String? v]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Теги — ${widget.ref}', 'Tags — ${widget.ref}')),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(
          hintText: tr('теги через запятую…', 'tags, comma-separated…'),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: _close,
      ),
      actions: [
        TextButton(
          onPressed: () => _close(),
          child: Text(tr('Отмена', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => _close(_ctrl.text),
          child: Text(tr('Сохранить', 'Save')),
        ),
      ],
    );
  }
}

/// Диалог заметки: свой ScrollController у TextField и unfocus перед
/// закрытием — на Android assert '_dependents.isEmpty' срабатывал, когда
/// внутренний Scrollable поля ещё зависел от PrimaryScrollController/
/// MediaQuery в момент удаления route диалога.
///
/// Запись-заметку диалог ведёт сам: вложениям нужен id записи сразу,
/// ещё до «Сохранить» (первый файл создаёт пустую заметку).
class NoteDialog extends StatefulWidget {
  const NoteDialog({
    super.key,
    required this.ref,
    required this.entry,
    required this.tagEntry,
    required this.moduleId,
    required this.book,
    required this.chapter,
    required this.verse,
    required this.contextText,
    this.frag = '',
    this.foreignCount,
  });

  final String ref;
  final UserEntry? entry;

  /// Селектор куска стиха — заметка на выделенную фразу (схема 4).
  final String frag;

  /// tag-запись стиха (теги редактируются вместе с заметкой).
  final UserEntry? tagEntry;
  final String moduleId, book, contextText;
  final int chapter, verse;

  /// Число записей других переводов к стиху (в.12, этап А); кнопка
  /// показывается, когда их больше нуля; тап закрывает диалог с
  /// результатом 'foreign' — список показывает вызывающий.
  final Future<int> Function()? foreignCount;

  @override
  State<NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<NoteDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: splitNote(widget.entry?.text ?? '').$2,
  );
  late final TextEditingController _titleCtrl = TextEditingController(
    text: splitNote(widget.entry?.text ?? '').$1,
  );
  late final TextEditingController _tagsCtrl = TextEditingController(
    text:
        widget.tagEntry?.text
            .split(',')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .join(', ') ??
        '',
  );
  final ScrollController _scroll = ScrollController();
  final AudioPlayer _player = AudioPlayer();

  String? _entryId;
  List<AttachInfo> _items = const [];
  bool _recording = false;
  String? _playingId;

  @override
  void initState() {
    super.initState();
    _entryId = widget.entry?.id;
    _reload();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _titleCtrl.dispose();
    _tagsCtrl.dispose();
    _scroll.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final id = _entryId;
    if (id == null) return;
    final items = await attachList(id);
    if (mounted) setState(() => _items = items);
  }

  /// Запись для вложения: при первом файле создаём пустую заметку.
  Future<String> _ensureEntry() async {
    var id = _entryId;
    if (id != null) return id;
    id = await bridgeEntryAdd(
      kind: 'note',
      module: widget.moduleId,
      book: widget.book,
      chapter: widget.chapter,
      verse: widget.verse,
      text: joinNote(_titleCtrl.text.trim(), _ctrl.text.trim()),
      context: widget.contextText,
      frag: widget.frag,
    );
    _entryId = id;
    // Диалог сам мутирует записи — извещает шину (B8): заметка с
    // вложениями создаётся до «Сохранить».
    userDataBus.changed(
      module: widget.moduleId,
      book: widget.book,
      chapter: widget.chapter,
    );
    return id!;
  }

  Future<void> _addPhoto() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    final f = files.firstOrNull;
    if (f == null) return;
    final bytes = await f.readAsBytes();
    final id = await _ensureEntry();
    final a = await attachAdd(
      entryId: id,
      name: f.name,
      mime: 'image/${f.extension ?? 'jpg'}',
      bytes: bytes,
    );
    if (a == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Файл слишком большой', 'File is too large')),
        ),
      );
    }
    await _reload();
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      final got = await attachRecordStop();
      if (mounted) setState(() => _recording = false);
      if (got != null) {
        final id = await _ensureEntry();
        await attachAdd(
          entryId: id,
          name: got.name,
          mime: got.mime,
          bytes: got.bytes,
        );
      }
      await _reload();
    } else {
      final ok = await attachRecordStart();
      if (mounted) setState(() => _recording = ok);
    }
  }

  Future<void> _togglePlay(AttachInfo a) async {
    if (_playingId == a.id) {
      await _player.stop();
      if (mounted) setState(() => _playingId = null);
      return;
    }
    final bytes = await attachBytes(a);
    if (bytes == null) return;
    await _player.play(BytesSource(bytes));
    if (mounted) setState(() => _playingId = a.id);
  }

  Future<void> _showImage(AttachInfo a) async {
    final bytes = await attachBytes(a);
    if (bytes == null || !mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: InteractiveViewer(child: Image.memory(bytes)),
      ),
    );
  }

  Future<void> _save() async {
    final text = joinNote(_titleCtrl.text.trim(), _ctrl.text.trim());
    var id = _entryId;
    var mutated = false;
    if (id != null) {
      // Заметка без текста, но с вложениями — остаётся.
      await bridgeEntryUpdate(id, text);
      mutated = true;
    } else if (text.isNotEmpty) {
      id = await bridgeEntryAdd(
        kind: 'note',
        module: widget.moduleId,
        book: widget.book,
        chapter: widget.chapter,
        verse: widget.verse,
        text: text,
        context: widget.contextText,
        frag: widget.frag,
      );
      _entryId = id;
      mutated = true;
    }
    // Теги стиха: одна tag-запись, текст — имена через запятую.
    final cleaned = [
      for (final t in _tagsCtrl.text.split(','))
        if (t.trim().isNotEmpty) t.trim(),
    ].join(',');
    final tag = widget.tagEntry;
    if (tag != null) {
      if (cleaned.isEmpty) {
        await bridgeEntryRemove(tag.id);
        mutated = true;
      } else {
        await bridgeEntryUpdate(tag.id, cleaned);
        mutated = true;
      }
    } else if (cleaned.isNotEmpty) {
      await bridgeEntryAdd(
        kind: 'tag',
        module: widget.moduleId,
        book: widget.book,
        chapter: widget.chapter,
        verse: widget.verse,
        text: cleaned,
        context: widget.contextText,
      );
      mutated = true;
    }
    // Пачка правок (заметка + теги) — одно извещение шины (B8):
    // перечитку делает подписчик; область — координаты диалога,
    // они могут не совпадать с открытым экраном (чужой перевод).
    if (mutated) {
      userDataBus.changed(
        module: widget.moduleId,
        book: widget.book,
        chapter: widget.chapter,
      );
    }
    _pop('save');
  }

  Future<void> _delete() async {
    final id = _entryId;
    if (id != null) {
      await attachRemoveFor(id);
      await bridgeEntryRemove(id);
      // Мутация извещает шину (B8).
      userDataBus.changed(
        module: widget.moduleId,
        book: widget.book,
        chapter: widget.chapter,
      );
    }
    _pop('delete');
  }

  void _pop(String action) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(action);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      // При открытой клавиатуре диалог сжимается — даём прокрутку.
      scrollable: true,
      title: Text(tr('Заметка — ${widget.ref}', 'Note — ${widget.ref}')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleCtrl,
              decoration: InputDecoration(
                hintText: tr('Название…', 'Title…'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              scrollController: _scroll,
              // При поднятой клавиатуре поле сжимаем — иначе и оно,
              // и кнопки уходят за край видимой области.
              maxLines: MediaQuery.of(context).viewInsets.bottom > 0 ? 4 : 6,
              autofocus: true,
              decoration: InputDecoration(
                hintText: tr('Текст заметки…', 'Note text…'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tagsCtrl,
              decoration: InputDecoration(
                icon: const Icon(Icons.label_outline, size: 18),
                hintText: tr('теги через запятую…', 'tags, comma-separated…'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            if (widget.foreignCount != null)
              FutureBuilder<int>(
                future: widget.foreignCount!(),
                builder: (context, snap) {
                  final n = snap.data ?? 0;
                  if (n <= 0) return const SizedBox.shrink();
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: Icon(Icons.translate, size: 16, color: p.accent),
                      label: Text(
                        tr(
                          'Записи в других переводах: $n',
                          'Entries in other translations: $n',
                        ),
                        style: TextStyle(fontSize: 13, color: p.accent),
                      ),
                      onPressed: () => _pop('foreign'),
                    ),
                  );
                },
              ),
            // Вложения и действия одним компактным рядом — под
            // клавиатурой обязаны оставаться видимыми.
            Row(
              children: [
                IconButton(
                  tooltip: tr('Прикрепить изображение', 'Attach image'),
                  icon: Icon(Icons.image_outlined, color: p.muted),
                  onPressed: _addPhoto,
                ),
                if (attachCanRecord())
                  IconButton(
                    tooltip: _recording
                        ? tr('Остановить запись', 'Stop recording')
                        : tr('Надиктовать аудио', 'Record audio'),
                    icon: Icon(
                      _recording ? Icons.stop_circle : Icons.mic_outlined,
                      color: _recording ? p.jesus : p.muted,
                    ),
                    onPressed: _toggleRecord,
                  ),
                if (_recording)
                  Text(
                    tr('Запись…', 'Recording…'),
                    style: TextStyle(color: p.jesus, fontSize: 12),
                  ),
                const Spacer(),
                if (widget.entry != null || _entryId != null)
                  IconButton(
                    tooltip: tr('Удалить заметку', 'Delete note'),
                    onPressed: _delete,
                    icon: Icon(Icons.delete_outline, color: p.jesus),
                  ),
                IconButton(
                  tooltip: tr('Отмена', 'Cancel'),
                  onPressed: () => _pop('cancel'),
                  icon: Icon(Icons.close, color: p.muted),
                ),
                IconButton.filled(
                  tooltip: tr('Сохранить', 'Save'),
                  onPressed: _save,
                  icon: const Icon(Icons.check),
                ),
              ],
            ),
            if (_items.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in _items)
                      InputChip(
                        avatar: Icon(
                          a.mime.startsWith('image/')
                              ? Icons.image
                              : (_playingId == a.id
                                    ? Icons.stop
                                    : Icons.play_arrow),
                          size: 16,
                        ),
                        label: Text(
                          a.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () => a.mime.startsWith('image/')
                            ? _showImage(a)
                            : _togglePlay(a),
                        onDeleted: () async {
                          await attachRemove(a.id);
                          await _reload();
                        },
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

String? _extractAttr(String attrs, String key) {
  final m = RegExp('$key="([^"]*)"').firstMatch(attrs);
  final v = m?.group(1);
  return (v != null && v.isNotEmpty) ? v : null;
}

Future<Map<String, dynamic>?> _loadExtendeStrong(
  String? modulePath,
  String strong,
  String attrs,
) async {
  if (modulePath == null || modulePath.isEmpty) return null;
  final morph = _extractAttr(attrs, 'morph') ?? '';
  final eid = _extractAttr(attrs, 'eid') ?? '';
  final ref = _extractAttr(attrs, 'ref') ?? _extractAttr(attrs, 'wid') ?? '';
  final sns = _extractAttr(attrs, 'sns') ?? '';
  final q = [
    '@lex:${normalizeStrong(strong) ?? strong}',
    'lang=${isEn ? "en" : "ru"}',
    if (morph.isNotEmpty) 'morph=$morph',
    if (eid.isNotEmpty) 'eid=$eid',
    if (ref.isNotEmpty) 'ref=$ref',
    if (sns.isNotEmpty) 'sns=$sns',
  ].join('|');
  final raw = await bridgeChapterDoc(modulePath, q, 1);
  if (raw == null || raw.isEmpty) return null;
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// Разбивает длинную статью или словарное определение на небольшие абзацы
/// (до [maxChars] символов), чтобы Flutter не держал один гигантский
/// RenderParagraph и не тормозил при скролле.
List<String> _splitIntoParagraphs(String text, {int maxChars = 900}) {
  final out = <String>[];
  for (final raw in text.split(RegExp(r'\n+'))) {
    final p = raw.trim();
    if (p.isEmpty) continue;
    if (p.length <= maxChars) {
      out.add(p);
      continue;
    }
    var start = 0;
    while (start < p.length) {
      var end = (start + maxChars).clamp(0, p.length);
      if (end < p.length) {
        final dot = p.lastIndexOf('. ', end);
        final sp = p.lastIndexOf(' ', end);
        if (dot > start + maxChars ~/ 2) {
          end = dot + 1;
        } else if (sp > start + maxChars ~/ 2) {
          end = sp;
        }
      }
      out.add(p.substring(start, end).trim());
      start = end;
    }
  }
  return out;
}

/// Порционный показ длинного текста (энциклопедической статьи или BDB/LSJ)
/// с изолированными `RepaintBoundary` на каждый абзац и кнопкой догрузки.
class _ChunkedLongText extends StatefulWidget {
  const _ChunkedLongText({
    required this.text,
    required this.style,
    required this.accentColor,
  });

  final String text;
  final TextStyle style;
  final Color accentColor;

  @override
  State<_ChunkedLongText> createState() => _ChunkedLongTextState();
}

class _ChunkedLongTextState extends State<_ChunkedLongText> {
  late final List<String> _paras = _splitIntoParagraphs(widget.text);
  int _visible = 6;

  @override
  Widget build(BuildContext context) {
    final shown = _paras.take(_visible).toList(growable: false);
    final rem = _paras.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < shown.length; i++)
          RepaintBoundary(
            child: Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
              child: Text(shown[i], style: widget.style),
            ),
          ),
        if (rem > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() => _visible += 12),
              icon: Icon(
                Icons.expand_more,
                size: 16,
                color: widget.accentColor,
              ),
              label: Text(
                tr('Показать ещё ($rem абз.)', 'Show more ($rem paragraphs)'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: widget.accentColor,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Карточка сущности из `knowledge` (ADR 0024).
void showEntityCard(BuildContext context, String modulePath, String entityId) {
  final p = context.palette;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      builder: (_, scrollCtrl) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: FutureBuilder<String?>(
            future: bridgeChapterDoc(modulePath, '@entity:$entityId', 1),
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return Text(
                  tr('Загружаю сущность…', 'Loading entity…'),
                  style: TextStyle(fontSize: 13, color: p.muted),
                );
              }
              final raw = snap.data;
              if (raw == null) {
                return Text(
                  tr(
                    'Сущность $entityId не найдена.',
                    'Entity $entityId not found.',
                  ),
                  style: TextStyle(fontSize: 13, color: p.muted),
                );
              }
              final ent = jsonDecode(raw) as Map<String, dynamic>;
              return ListView(
                controller: scrollCtrl,
                children: [
                  RepaintBoundary(
                    child: _buildEntitySection(ctx, p, ent, modulePath),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

const _entityTypeRu = <String, String>{
  'person': 'человек',
  'place': 'место',
  'group': 'группа / народ',
  'deity': 'божество / дух',
  'creature': 'животное',
  'plant': 'растение',
  'object': 'предмет',
  'concept': 'понятие',
};

const _relationTypeRu = <String, String>{
  'father': 'отец',
  'mother': 'мать',
  'partner': 'супруг(а)',
  'offspring': 'ребёнок',
  'sibling': 'брат/сестра',
  'member_of': 'колено/группа',
  'subregion_of': 'область',
  'tribal_area': 'удел',
  'nearby': 'рядом',
  'associated': 'связано с',
  'born_in': 'место рождения',
  'died_in': 'место смерти',
  'origin_person': 'родоначальник',
  'possibly_same': 'возможно, тождественен',
};

Widget _buildEntitySection(
  BuildContext context,
  Palette p,
  Map<String, dynamic> ent,
  String? modulePath,
) {
  final name = ent['name'] as String? ?? '';
  final typ = ent['type'] as String? ?? '';
  final sub = ent['subtype'] as String? ?? '';
  final orig = ent['name_original'] as String? ?? '';
  final meaningRu = ent['name_meaning_ru'] as String? ?? '';
  final meaningEn = ent['name_meaning_en'] as String? ?? '';
  final accentedRu = ent['name_accented_ru'] as String? ?? '';
  final descEn = ent['short_description'] as String? ?? '';
  final descRu = ent['short_description_ru'] as String? ?? '';
  final articleEn = ent['article'] as String? ?? '';
  final articleRu = ent['article_ru'] as String? ?? '';
  final namesRu = (ent['names_ru'] as List? ?? const []).cast<String>();
  final rels = (ent['relations'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final desc = tr(
    descRu.isNotEmpty ? descRu : descEn,
    descEn.isNotEmpty ? descEn : descRu,
  );
  final article = tr(
    articleRu.isNotEmpty ? articleRu : articleEn,
    articleEn.isNotEmpty ? articleEn : articleRu,
  );
  final meaning = tr(
    meaningRu.isNotEmpty ? meaningRu : meaningEn,
    meaningEn.isNotEmpty ? meaningEn : meaningRu,
  );
  final headRu = accentedRu.isNotEmpty
      ? accentedRu
      : (namesRu.isNotEmpty ? namesRu.first : '');
  final typLabel = tr(_entityTypeRu[typ] ?? typ, typ);

  return Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: p.accent.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: p.accent.withValues(alpha: 0.25)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              typ == 'place' ? Icons.place_outlined : Icons.person_outline,
              size: 18,
              color: p.accent,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                [if (headRu.isNotEmpty) headRu, name].join(' · '),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
            ),
            Text(
              [typLabel, if (sub.isNotEmpty) sub].join(' / '),
              style: TextStyle(fontSize: 11, color: p.muted),
            ),
          ],
        ),
        if (orig.isNotEmpty || meaning.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              [
                if (orig.isNotEmpty) orig,
                if (meaning.isNotEmpty)
                  tr('Значение: $meaning', 'Meaning: $meaning'),
              ].join(' · '),
              style: TextStyle(fontSize: 13, color: p.muted),
            ),
          ),
        if (desc.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              desc,
              style: TextStyle(fontSize: 13, color: p.ink, height: 1.35),
            ),
          ),
        if (rels.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final r in rels.take(12))
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(() {
                    final rt = r['type'] as String? ?? '';
                    final rtLabel = tr(_relationTypeRu[rt] ?? rt, rt);
                    final nRu = r['name_ru'] as String? ?? '';
                    final nEn = r['name'] as String? ?? '';
                    final targetLabel = tr(nRu.isNotEmpty ? nRu : nEn, nEn);
                    return '$rtLabel: $targetLabel';
                  }(), style: const TextStyle(fontSize: 11)),
                  onPressed: modulePath != null && modulePath.isNotEmpty
                      ? () => showEntityCard(
                          context,
                          modulePath,
                          r['id'] as String? ?? '',
                        )
                      : null,
                ),
            ],
          ),
        ],
        if (article.isNotEmpty) ...[
          const SizedBox(height: 6),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              tr('Энциклопедическая статья', 'Encyclopedia article'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.accent,
              ),
            ),
            children: [
              _ChunkedLongText(
                text: article,
                style: TextStyle(fontSize: 12.5, color: p.ink, height: 1.4),
                accentColor: p.accent,
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

/// Карточка статьи словаря Стронга — шторка. Используется из
/// экрана чтения (тап по слову с номером) и из истории.
void showStrongCard(
  BuildContext context,
  String strong,
  String word, {
  String attrs = '',
  String? modulePath,

  /// Действие «Все вхождения» (DECISIONS 18.10.2026 «От слова к стихам
  /// через Strong»): шторка закрывается, затем колбэк получает
  /// нормализованный ПЕРВЫЙ код (строка может нести несколько номеров).
  /// Дальше читатель/история открывают экран поиска, где при
  /// initialQuery с кодом уже работает автоматический обратный поиск
  /// Strong (bridgeModuleStrongSearch) — нового кода моста не нужно.
  /// null — кнопки нет (вызов из поиска: все стихи уже на экране).
  void Function(String strong)? onFindVerses,
}) {
  final p = context.palette;
  // Код для «Все вхождения» считаем до шторки: кнопка живёт в шапке,
  // вне FutureBuilder, и показывается не дожидаясь статьи словаря.
  final findCode = (normalizeStrong(strong) ?? strong).split(' ').first;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      builder: (ctx, scrollCtrl) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Шапка карточки — вне FutureBuilder: код, слово и
              // действие видны сразу, не дожидаясь загрузки словаря.
              Text(
                strong,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: p.accent,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '«${word.trim()}»',
                style: TextStyle(fontSize: 16, color: p.ink),
              ),
              if (onFindVerses != null) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    // Сначала закрываем шторку, потом действие —
                    // как у остальных «pop, затем колбэк» здесь.
                    Navigator.of(ctx).pop();
                    onFindVerses(findCode);
                  },
                  icon: const Icon(Icons.manage_search, size: 18),
                  label: Text(tr('Все вхождения', 'All occurrences')),
                  style: FilledButton.styleFrom(
                    backgroundColor: p.accent,
                    foregroundColor: p.onAccent,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child:
                    FutureBuilder<
                      (Map<String, dynamic>?, Map<String, LexiconEntry>)
                    >(
                      future: () async {
                        final ext = await _loadExtendeStrong(
                          modulePath,
                          strong,
                          attrs,
                        );
                        final dict = await lexicon();
                        return (ext, dict);
                      }(),
                      builder: (_, snap) {
                        final ext = snap.data?.$1;
                        final extEntries =
                            (ext?['entries'] as List? ?? const [])
                                .cast<Map<String, dynamic>>();
                        final extMorphs = (ext?['morph'] as List? ?? const [])
                            .cast<Map<String, dynamic>>();
                        final extEntity =
                            ext?['entity'] as Map<String, dynamic>?;
                        final ctxSense = ext?['context_sense'] as String? ?? '';
                        final dict = snap.data?.$2;
                        final firstCode = (normalizeStrong(strong) ?? strong)
                            .split(' ')
                            .first;
                        final e =
                            dict?[firstCode] ??
                            dict?[firstCode.replaceAll(RegExp(r'[A-Z]$'), '')];

                        // Код и слово — в шапке карточки (выше, вне FutureBuilder).
                        final items = <Widget>[
                          if (ctxSense.isNotEmpty)
                            _strongLine(
                              p,
                              tr(
                                'Контекстное значение в стихе',
                                'Contextual sense in verse',
                              ),
                              ctxSense,
                            ),
                          if (extMorphs.isNotEmpty)
                            _strongLine(
                              p,
                              tr('Морфология', 'Morphology'),
                              [
                                for (final m in extMorphs)
                                  '${m['code']}: ${m['long'] ?? m['short'] ?? ''}',
                              ].join('\n'),
                            ),
                          if (extEntity != null)
                            _buildEntitySection(ctx, p, extEntity, modulePath),
                          const SizedBox(height: 8),
                          if (extEntries.isNotEmpty)
                            for (final ee in extEntries) ...[
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  [
                                    ee['key'] as String? ?? '',
                                    ee['lemma'] as String? ?? '',
                                    ee['xlit'] as String? ?? '',
                                  ].where((s) => s.isNotEmpty).join('  ·  '),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: p.ink,
                                  ),
                                ),
                              ),
                              if ((ee['gloss'] as String? ?? '').isNotEmpty)
                                _strongLine(
                                  p,
                                  tr(
                                    'Краткое толкование (STEPBible)',
                                    'STEPBible Gloss',
                                  ),
                                  ee['gloss'] as String,
                                ),
                              if ((ee['sense_label'] as String? ?? '')
                                  .isNotEmpty)
                                _strongLine(
                                  p,
                                  tr('Метка значения', 'Sense label'),
                                  ee['sense_label'] as String,
                                ),
                              if ((ee['sense_domain'] as String? ?? '')
                                  .isNotEmpty)
                                _strongLine(
                                  p,
                                  tr(
                                    'Семантический домен (UBS, CC BY-SA 4.0)',
                                    'Semantic domain (UBS, CC BY-SA 4.0)',
                                  ),
                                  ee['sense_domain'] as String,
                                ),
                              // lex_lxx (аддитивная таблица словаря):
                              // греческие эквиваленты еврейской базы.
                              if ((ee['lxx'] as List? ?? const [])
                                  .isNotEmpty)
                                _strongLine(
                                  p,
                                  tr(
                                    'Как передано в LXX',
                                    'Rendered in the LXX as',
                                  ),
                                  (ee['lxx'] as List)
                                      .cast<Map<String, dynamic>>()
                                      .map((x) {
                                        final lm = '${x['lemma'] ?? ''}'
                                            .trim();
                                        final g = '${x['g'] ?? ''}'.trim();
                                        final gl = '${x['gloss'] ?? ''}'
                                            .trim();
                                        final head = lm.isEmpty
                                            ? g
                                            : (g.isEmpty ? lm : '$lm ($g)');
                                        return gl.isNotEmpty
                                            ? '$head — $gl'
                                            : head;
                                      })
                                      .join('; '),
                                ),
                              for (final d
                                  in (ee['defs'] as List? ?? const [])
                                      .cast<Map<String, dynamic>>())
                                _strongLine(
                                  p,
                                  '${d['src']} (${d['lic']})',
                                  d['def'] as String? ?? '',
                                ),
                            ]
                          else if (e == null)
                            Text(
                              snap.hasData
                                  ? tr(
                                      'Нет статьи $strong в словаре.',
                                      'No lexicon entry for $strong.',
                                    )
                                  : tr('Загружаю словарь…', 'Loading lexicon…'),
                              style: TextStyle(fontSize: 13, color: p.muted),
                            )
                          else ...[
                            if (e.lemma.isNotEmpty || e.xlit.isNotEmpty)
                              Text(
                                [
                                  e.lemma,
                                  e.xlit,
                                  e.pron,
                                ].where((s) => s.isNotEmpty).join('  ·  '),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: p.ink,
                                ),
                              ),
                            if (e.pos.isNotEmpty)
                              _strongLine(
                                p,
                                tr('Часть речи', 'Part of speech'),
                                e.pos,
                              ),
                            if (e.expl.isNotEmpty)
                              _strongLine(
                                p,
                                tr('Определение', 'Definition'),
                                e.expl,
                              ),
                            for (final d in e.defs)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  '• $d',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: p.ink,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            if (e.deriv.isNotEmpty)
                              _strongLine(
                                p,
                                tr('Происхождение', 'Derivation'),
                                e.deriv,
                              ),
                            if (e.kjv.isNotEmpty)
                              _strongLine(p, tr('В KJV', 'In KJV'), e.kjv),
                          ],
                        ];

                        return ListView.builder(
                          controller: scrollCtrl,
                          itemCount: items.length,
                          itemBuilder: (_, i) =>
                              RepaintBoundary(child: items[i]),
                        );
                      },
                    ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _strongLine(Palette p, String label, String text) => Padding(
  padding: const EdgeInsets.only(top: 8),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: p.muted,
        ),
      ),
      if (text.length > 900)
        _ChunkedLongText(
          text: text,
          style: TextStyle(fontSize: 13, color: p.ink, height: 1.35),
          accentColor: p.accent,
        )
      else
        Text(text, style: TextStyle(fontSize: 13, color: p.ink, height: 1.35)),
    ],
  ),
);
