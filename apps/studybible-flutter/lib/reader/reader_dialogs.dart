import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../attachments_stub.dart'
    if (dart.library.io) '../attachments_io.dart'
    if (dart.library.html) '../attachments_web.dart';
import '../l10n.dart';
import '../lexicon.dart';
import '../state.dart' show splitNote, joinNote;
import '../native_bridge.dart' show UserEntry;
import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.html) '../native_bridge_web.dart';
import '../theme.dart';

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
    this.foreignCount,
  });

  final String ref;
  final UserEntry? entry;

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
    );
    _entryId = id;
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
    if (id != null) {
      // Заметка без текста, но с вложениями — остаётся.
      await bridgeEntryUpdate(id, text);
    } else if (text.isNotEmpty) {
      id = await bridgeEntryAdd(
        kind: 'note',
        module: widget.moduleId,
        book: widget.book,
        chapter: widget.chapter,
        verse: widget.verse,
        text: text,
        context: widget.contextText,
      );
      _entryId = id;
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
      } else {
        await bridgeEntryUpdate(tag.id, cleaned);
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
    }
    _pop('save');
  }

  Future<void> _delete() async {
    final id = _entryId;
    if (id != null) {
      await attachRemoveFor(id);
      await bridgeEntryRemove(id);
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

/// Карточка статьи словаря Стронга — шторка. Используется из
/// экрана чтения (тап по слову с номером) и из истории.
void showStrongCard(BuildContext context, String strong, String word) {
  final p = context.palette;
  showModalBottomSheet(
    context: context,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: FutureBuilder<Map<String, LexiconEntry>>(
          future: lexicon(),
          builder: (_, snap) {
            final e = snap.data?[normalizeStrong(strong) ?? strong];
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strong,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: p.accent,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '«${word.trim()}»',
                    style: TextStyle(fontSize: 16, color: p.ink),
                  ),
                  const SizedBox(height: 8),
                  if (e == null)
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
                      _strongLine(p, tr('Часть речи', 'Part of speech'), e.pos),
                    if (e.expl.isNotEmpty)
                      _strongLine(p, tr('Определение', 'Definition'), e.expl),
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
                ],
              ),
            );
          },
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
      Text(text, style: TextStyle(fontSize: 13, color: p.ink, height: 1.35)),
    ],
  ),
);
