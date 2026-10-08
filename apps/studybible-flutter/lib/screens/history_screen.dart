import 'package:flutter/material.dart';

import '../l10n.dart';
import '../data.dart';
import '../native_bridge.dart' show UserEntry;
import '../state.dart';
import '../reader/reader_dialogs.dart';
import '../theme.dart';
import 'reading_screen.dart';
import 'search_screen.dart';
import '../routes.dart';

/// Экран «История»: сквозная лента переходов — главы/стихи по всем
/// переводам, обращения к словарю Стронга, поисковые запросы
/// (userdata.db). Тап — возврат к тому же месту.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.onBack, this.onOpenVerse});

  /// Встроенный режим (экран-позиция рабочего места): «назад» и тап
  /// по стиху идут через стек читалки, а не через Navigator.
  final VoidCallback? onBack;
  final OpenVerse? onOpenVerse;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    history.load();
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _tile(UserEntry e, Palette p) {
    final t = _fmt(e.updated);
    if (e.text == 'hist:dict') {
      // Словарь Стронга: 'H3117|слово' в context.
      final parts = e.context.split('|');
      final strong = parts.first;
      final word = parts.length > 1 ? parts.sublist(1).join('|') : '';
      return ListTile(
        dense: true,
        leading: Icon(Icons.translate, size: 18, color: p.muted),
        title: Text(
          '$strong${word.isEmpty ? '' : ' · «$word»'}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${tr('Словарь Стронга', "Strong's lexicon")} · $t',
          style: TextStyle(fontSize: 12, color: p.muted),
        ),
        trailing: Icon(Icons.chevron_right, size: 18, color: p.muted),
        onTap: () => showStrongCard(context, strong, word),
      );
    }
    if (e.text == 'hist:search') {
      return ListTile(
        dense: true,
        leading: Icon(Icons.search, size: 18, color: p.muted),
        title: Text(
          '«${e.context}»',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${tr('Поиск', 'Search')} · $t',
          style: TextStyle(fontSize: 12, color: p.muted),
        ),
        trailing: Icon(Icons.chevron_right, size: 18, color: p.muted),
        onTap: () =>
            Navigator.of(context)
                .push(fastRoute(SearchScreen(initialQuery: e.context))),
      );
    }
    final book = bookShort(e.book);
    final module = moduleName(e.module);
    final verse = e.verse > 0 ? ':${e.verse}' : '';
    return ListTile(
      dense: true,
      leading: Icon(Icons.menu_book_outlined, size: 18, color: p.muted),
      title: Text(
        '$book ${e.chapter}$verse',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '$module · $t',
        style: TextStyle(fontSize: 12, color: p.muted),
      ),
      trailing: Icon(Icons.chevron_right, size: 18, color: p.muted),
      onTap: widget.onOpenVerse != null
          ? () => widget.onOpenVerse!(e.module, e.book, e.chapter, e.verse)
          : () => Navigator.of(context).push(
              fastRoute(
                ReadingScreen(
                  bookCode: e.book,
                  chapter: e.chapter,
                  verse: e.verse > 0 ? e.verse : null,
                  moduleId: e.module,
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              ),
        title: Text(tr('История', 'History')),
      ),
      body: ListenableBuilder(
        listenable: history,
        builder: (_, _) {
          if (history.items.isEmpty) {
            return Center(
              child: Text(
                tr(
                  'История пуста — откройте любую главу',
                  'History is empty — open any chapter',
                ),
                style: TextStyle(color: p.muted),
              ),
            );
          }
          return ListView.builder(
            itemCount: history.items.length,
            itemBuilder: (context, i) => _tile(history.items[i], p),
          );
        },
      ),
    );
  }
}
