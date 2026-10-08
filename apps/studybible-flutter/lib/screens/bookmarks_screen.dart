import 'package:flutter/material.dart';

import '../data.dart';
import '../l10n.dart';
import '../state.dart';
import '../native_bridge.dart' show UserEntry;
import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.html) '../native_bridge_web.dart';
import '../theme.dart';
import '../userdata_stub.dart' if (dart.library.io) '../userdata_io.dart';
import 'reading_screen.dart';
import '../routes.dart';

/// Экран «Закладки и теги»: список закладок + все записи, сгруппированные
/// по тегам. Тап по элементу открывает экран чтения на месте стиха.
class BookmarksScreen extends StatefulWidget {
  const BookmarksScreen({super.key});

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<BookmarksScreen> {
  List<UserEntry> _marks = [];

  /// Тег -> записи, помеченные им (tag/notes к стихам).
  final Map<String, List<UserEntry>> _byTag = {};

  /// Выбранный тег-фильтр; null — все.
  String? _tag;

  /// Id записей-сирот последнего прогона relink (секция
  /// «Потерянные»: модуль есть, якорного стиха/контекста в нём нет).
  Set<String> _orphans = {};

  @override
  void initState() {
    super.initState();
    _load();
    notes.load();
  }

  Future<void> _load() async {
    // Служебные записи kind='mark' убираем: прогресс ('*'), настройки
    // ('settings') и элементы сквозной истории (text начинается с 'hist').
    bool real(UserEntry e) =>
        e.module != '*' && e.module != 'settings' && !e.text.startsWith('hist');
    // Записи группируются по переводу (в.12, этап А), внутри — по дате.
    final marks = (await bridgeEntriesList('mark')).where(real).toList()
      ..sort(
        (a, b) => a.module == b.module
            ? b.created.compareTo(a.created)
            : a.module.compareTo(b.module),
      );
    final tags = <String, List<UserEntry>>{};
    // Имена тегов — в text tag-записей через запятую.
    for (final e in (await bridgeEntriesList('tag')).where(real)) {
      for (final t in e.text.split(',')) {
        final name = t.trim();
        if (name.isNotEmpty) tags.putIfAbsent(name, () => []).add(e);
      }
    }
    final orphans = (await bridgeOrphanIds()).toSet();
    if (!mounted) return;
    setState(() {
      _marks = marks;
      _orphans = orphans;
      _byTag
        ..clear()
        ..addEntries(tags.entries);
      if (_tag != null && !_byTag.containsKey(_tag)) _tag = null;
    });
  }

  void _open(UserEntry e) {
    Navigator.of(context).push(
      fastRoute(
        ReadingScreen(
          bookCode: e.book,
          chapter: e.chapter,
          verse: e.verse,
          moduleId: e.module,
        ),
      ),
    );
  }

  Widget _tile(UserEntry e, IconData icon, Palette p) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18, color: p.accent),
      title: Text(
        '${bookShort(e.book)} ${e.chapter}:${e.verse} — ${moduleName(e.module)}',
        style: TextStyle(color: p.ink, fontWeight: FontWeight.w600),
      ),
      subtitle: e.context.isEmpty
          ? null
          : Text(
              e.context,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
      trailing: IconButton(
        icon: Icon(Icons.close, size: 16, color: p.muted),
        tooltip: tr('Удалить', 'Delete'),
        onPressed: () async {
          await bridgeEntryRemove(e.id);
          await _load();
        },
      ),
      onTap: () => _open(e),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tags = _byTag.keys.toList()..sort();
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.background,
        // Вкладка «Записи» (ADR 0015): закладки + теги + заметки.
        title: Text(tr('Записи', 'Notes'), style: TextStyle(color: p.ink)),
        iconTheme: IconThemeData(color: p.ink),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined, size: 20),
            tooltip: tr('Импорт записей', 'Import entries'),
            onPressed: () async {
              final msg = await importEntriesZip();
              if (msg == null || !context.mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(msg)));
              await _load();
              await notes.load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.file_download_outlined, size: 20),
            tooltip: tr('Экспорт записей', 'Export entries'),
            onPressed: () async {
              final msg = await exportEntriesZip();
              if (msg == null || !context.mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(msg)));
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          if (tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  FilterChip(
                    label: Text(tr('Все', 'All')),
                    selected: _tag == null,
                    onSelected: (_) => setState(() => _tag = null),
                  ),
                  for (final t in tags)
                    FilterChip(
                      label: Text('#$t'),
                      selected: _tag == t,
                      onSelected: (_) => setState(() => _tag = t),
                    ),
                ],
              ),
            ),
          if (_tag == null) ...[
            _header(tr('Заметки', 'Notes'), p),
            _noteComposer(),
            ListenableBuilder(
              listenable: notes,
              builder: (_, _) => Column(
                children: [
                  if (notes.items.isEmpty)
                    _empty(tr('Заметок пока нет', 'No notes yet'), p),
                  ..._groupedNotes(p),
                ],
              ),
            ),
            _header(tr('Закладки', 'Bookmarks'), p),
            if (_marks.isEmpty)
              _empty(tr('Закладок пока нет', 'No bookmarks yet'), p),
            ..._grouped(
              _marks.where((e) => !_orphans.contains(e.id)).toList(),
              p,
              (m) => _tile(m, Icons.bookmark, p),
            ),
            ..._orphanSection(p),
          ],
          if (_tag != null) ...[
            _header('#$_tag', p),
            for (final e in _byTag[_tag]!) _tile(e, Icons.label, p),
          ] else if (_byTag.isNotEmpty) ...[
            _header(tr('По тегам', 'By tag'), p),
            for (final t in tags) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  '#$t',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final e in _byTag[t]!) _tile(e, Icons.label, p),
            ],
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Кнопка «новая заметка» → диалог с названием и текстом.
  Widget _noteComposer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          icon: const Icon(Icons.add, size: 18),
          label: Text(tr('Новая заметка', 'New note')),
          onPressed: () => _noteDialog(),
        ),
      ),
    );
  }

  /// Диалог создания/правки заметки: название + текст.
  Future<void> _noteDialog({NoteItem? n}) async {
    final p = context.palette;
    final title = TextEditingController(text: n?.title ?? '');
    final body = TextEditingController(text: n?.text ?? '');
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Заметка', 'Note')),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: InputDecoration(
                  hintText: tr('Название…', 'Title…'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: body,
                autofocus: true,
                maxLines: 6,
                minLines: 3,
                decoration: InputDecoration(
                  hintText: tr('Текст заметки…', 'Note text…'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (n != null)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('delete'),
              child: Text(
                tr('Удалить', 'Delete'),
                style: TextStyle(color: p.accent),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: Text(tr('Сохранить', 'Save')),
          ),
        ],
      ),
    );
    if (action == 'save') {
      if (n == null) {
        await notes.add(title.text, body.text);
      } else {
        await notes.edit(n, title.text, body.text);
      }
    } else if (action == 'delete' && n != null) {
      await notes.remove(n);
    }
    title.dispose();
    body.dispose();
  }

  Widget _noteTile(NoteItem n, Palette p) {
    return ListTile(
      dense: true,
      leading: Icon(Icons.sticky_note_2_outlined, size: 18, color: p.accent),
      title: Text(
        n.title.isEmpty ? n.text : n.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.ink, fontSize: 14),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (n.title.isNotEmpty && n.text.isNotEmpty)
            Text(
              n.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.ink.withValues(alpha: 0.75),
                fontSize: 12,
              ),
            ),
          Text(
            [
              if (n.anchored)
                '${bookShort(n.book)} ${n.chapter}:${n.verse}'
                    ' — ${moduleName(n.module)}',
              '${n.created.day.toString().padLeft(2, '0')}.'
                  '${n.created.month.toString().padLeft(2, '0')}.'
                  '${n.created.year}',
            ].join(' · '),
            style: TextStyle(color: p.muted, fontSize: 11),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.edit_outlined, size: 16, color: p.muted),
            tooltip: tr('Править', 'Edit'),
            onPressed: () => _noteDialog(n: n),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: p.muted),
            tooltip: tr('Удалить', 'Delete'),
            onPressed: () => notes.remove(n),
          ),
        ],
      ),
      // Заметка к стиху: тап по плитке открывает её место.
      onTap: n.anchored
          ? () => _open(
              UserEntry(
                id: n.id,
                module: n.module,
                kind: 'note',
                book: n.book,
                chapter: n.chapter,
                verse: n.verse,
                text: n.text,
                context: '',
                created: n.created.millisecondsSinceEpoch,
                updated: n.created.millisecondsSinceEpoch,
              ),
            )
          : () => _noteDialog(n: n),
    );
  }

  /// Заметки с подзаголовками-переводами (в.12, этап А): список уже
  /// отсортирован по module; свободные заметки — без подзаголовка.
  List<Widget> _groupedNotes(Palette p) {
    final out = <Widget>[];
    var last = '';
    for (final n in notes.items) {
      // Сироты живут в секции «Потерянные», здесь не дублируем.
      if (_orphans.contains(n.id)) continue;
      if (n.module != last) {
        last = n.module;
        if (n.module.isNotEmpty) {
          out.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                moduleName(n.module),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }
      }
      out.add(_noteTile(n, p));
    }
    return out;
  }

  /// Секция «Потерянные»: сироты последнего relink'а — записи, чьего
  /// якорного стиха/контекста в модуле больше нет. Перехода нет
  /// (привязки нет); показаны координата на момент записи и текст.
  List<Widget> _orphanSection(Palette p) {
    if (_orphans.isEmpty) return const [];
    final lost = _marks.where((e) => _orphans.contains(e.id)).toList();
    final lostNotes = notes.items.where((n) => _orphans.contains(n.id));
    for (final n in lostNotes) {
      lost.add(
        UserEntry(
          id: n.id,
          module: n.module,
          kind: 'note',
          book: n.book,
          chapter: n.chapter,
          verse: n.verse,
          text: n.text,
          context: '',
          created: n.created.millisecondsSinceEpoch,
          updated: n.created.millisecondsSinceEpoch,
        ),
      );
    }
    if (lost.isEmpty) return const [];
    return [
      _header(tr('Потерянные', 'Lost'), p),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          tr(
            'Привязки к стиху больше нет — текст записи сохранён.',
            'Anchor no longer exists — the entry text is kept.',
          ),
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
      ),
      for (final e in lost)
        ListTile(
          dense: true,
          leading: Icon(Icons.link_off, size: 18, color: p.muted),
          title: Text(
            '${bookShort(e.book)} ${e.chapter}:${e.verse} — ${moduleName(e.module)}',
            style: TextStyle(color: p.ink, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            e.text.isEmpty ? e.context : e.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.muted, fontSize: 12),
          ),
          trailing: IconButton(
            icon: Icon(Icons.close, size: 16, color: p.muted),
            tooltip: tr('Удалить', 'Delete'),
            onPressed: () async {
              await bridgeEntryRemove(e.id);
              await _load();
              await notes.load();
            },
          ),
        ),
    ];
  }

  /// Плитки с подзаголовками-переводами (в.12, этап А): список уже
  /// отсортирован по module — подзаголовок печатаем при смене.
  List<Widget> _grouped(
    List<UserEntry> items,
    Palette p,
    Widget Function(UserEntry) tile,
  ) {
    final out = <Widget>[];
    var last = '';
    for (final e in items) {
      if (e.module != last) {
        last = e.module;
        out.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              moduleName(e.module),
              style: TextStyle(
                color: p.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      }
      out.add(tile(e));
    }
    return out;
  }

  Widget _header(String text, Palette p) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: TextStyle(color: p.ink, fontSize: 15, fontWeight: FontWeight.w700),
    ),
  );

  Widget _empty(String text, Palette p) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Text(text, style: TextStyle(color: p.muted, fontSize: 13)),
  );
}
