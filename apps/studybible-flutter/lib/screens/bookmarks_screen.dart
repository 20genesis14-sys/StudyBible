import 'package:flutter/material.dart';

import '../data.dart';
import '../l10n.dart';
import '../native_bridge.dart' show UserEntry;
import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.html) '../native_bridge_web.dart';
import '../theme.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Служебные записи kind='mark' убираем: прогресс ('*'), настройки
    // ('settings') и элементы сквозной истории (text начинается с 'hist').
    bool real(UserEntry e) =>
        e.module != '*' && e.module != 'settings' && !e.text.startsWith('hist');
    final marks = (await bridgeEntriesList('mark')).where(real).toList()
      ..sort((a, b) => b.created.compareTo(a.created));
    final tags = <String, List<UserEntry>>{};
    // Имена тегов — в text tag-записей через запятую.
    for (final e in (await bridgeEntriesList('tag')).where(real)) {
      for (final t in e.text.split(',')) {
        final name = t.trim();
        if (name.isNotEmpty) tags.putIfAbsent(name, () => []).add(e);
      }
    }
    if (!mounted) return;
    setState(() {
      _marks = marks;
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
        '${kShortName[e.book] ?? e.book} ${e.chapter}:${e.verse} — ${kModules[e.module] ?? e.module}',
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
        title: Text(
          tr('Закладки', 'Bookmarks'),
          style: TextStyle(color: p.ink),
        ),
        iconTheme: IconThemeData(color: p.ink),
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
            _header(tr('Закладки', 'Bookmarks'), p),
            if (_marks.isEmpty)
              _empty(tr('Закладок пока нет', 'No bookmarks yet'), p),
            for (final m in _marks) _tile(m, Icons.bookmark, p),
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
