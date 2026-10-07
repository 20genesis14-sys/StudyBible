import 'package:flutter/material.dart';

import '../l10n.dart';
import '../data.dart';
import '../native_bridge.dart' show SearchHit;
import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.html) '../native_bridge_web.dart';
import '../state.dart';
import '../theme.dart';
import 'reading_screen.dart';
import '../routes.dart';

/// Поиск по тексту модуля (FTS5-индекс ядра; на web — LIKE-фоллбэк).
/// Тап по результату — переход к стиху в текущем переводе.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.moduleId, this.initialQuery});

  /// Модуль, из которого открыли поиск (предвыбор в дрopdown).
  final String? moduleId;

  /// Запрос из истории — подставляется в поле и сразу выполняется.
  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  // Поиск — по переводу, из которого открыли экран (или основному);
  // выбор перевода внутри поиска убран по решению UX.
  late final String _moduleId = widget.moduleId ?? mainModuleId();
  List<SearchHit> _hits = const [];
  bool _busy = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _query.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  Future<void> _run() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    history.touchSearch(q);
    setState(() {
      _busy = true;
      _notice = null;
    });
    final path = modulePathOf(_moduleId);
    if (path == null) {
      setState(() {
        _busy = false;
        _hits = const [];
        _notice = tr(
          'Для этого модуля нет .sb — поиск недоступен.',
          'No .sb for this module — search unavailable.',
        );
      });
      return;
    }
    final hits = await bridgeModuleSearch(path, q, limit: 100);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hits = hits;
      if (hits.isEmpty) _notice = tr('Ничего не найдено.', 'Nothing found.');
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Поиск', 'Search'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _query,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _run(),
                        decoration: InputDecoration(
                          hintText: tr('Слово или фраза…', 'Word or phrase…'),
                          border: OutlineInputBorder(),
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _busy ? null : _run,
                      child: Text(tr('Найти', 'Search')),
                    ),
                  ],
                ),

              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_notice!, style: TextStyle(color: p.muted)),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _hits.length,
              itemBuilder: (context, i) {
                final h = _hits[i];
                final book = bookShort(h.book);
                return ListTile(
                  dense: true,
                  title: Text(
                    '$book ${h.chapter}:${h.verse}',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: p.accent,
                    ),
                  ),
                  subtitle: Text(
                    h.snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.ink),
                  ),
                  onTap: () => Navigator.of(context).push(
                    fastRoute(
                      ReadingScreen(
                        bookCode: h.book,
                        chapter: h.chapter,
                        verse: h.verse,
                        moduleId: _moduleId,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
