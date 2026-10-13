import 'package:flutter/material.dart';

import '../l10n.dart';
import '../data.dart';
import '../native_bridge.dart' show SearchHit;
import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.js_interop) '../native_bridge_web.dart';
import '../state.dart';
import '../theme.dart';
import 'reading_screen.dart';
import '../routes.dart';

/// Поиск по тексту модуля (FTS5-индекс ядра; на web — LIKE-фоллбэк).
/// Тап по результату — переход к стиху в текущем переводе.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    this.moduleId,
    this.initialQuery,
    this.onBack,
    this.onOpenVerse,
  });

  /// Модуль, из которого открыли поиск (предвыбор в дрopdown).
  final String? moduleId;

  /// Запрос из истории — подставляется в поле и сразу выполняется.
  final String? initialQuery;

  /// Встроенный режим (экран-позиция рабочего места): «назад» и тап
  /// по результату идут через стек читалки, а не через Navigator.
  final VoidCallback? onBack;
  final OpenVerse? onOpenVerse;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  // Поиск — по переводу, из которого открыли экран (или основному);
  // выбор перевода внутри поиска убран по решению UX.
  late final String _moduleId = widget.moduleId ?? mainModuleId();
  static const _searchLimit = 100;
  List<SearchHit> _hits = const [];
  bool _busy = false;
  String? _notice;

  /// Вид результатов — состояние экрана, сессия (DECISIONS «Поиск»).
  /// Стартует из settings.searchResultsView (скрытая возможность
  /// «запоминать вид»), но назад не пишется.
  late SearchResultsView _view = settings.searchResultsView;

  /// Раскрытые книги в режиме «По книгам».
  final Set<String> _expanded = {};

  /// Область поиска: текст стихов или сноски/параллельные места.
  bool _notes = false;

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
    final hits = _notes
        ? await bridgeNotesSearch(path, q, limit: _searchLimit)
        : await bridgeModuleSearch(path, q, limit: _searchLimit);
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
      appBar: AppBar(
        leading: widget.onBack == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              ),
        title: Text(tr('Поиск', 'Search')),
      ),
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
                // Область: стихи или сноски/параллельные (те же
                // операторы запроса в обоих режимах).
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilterChip(
                      selected: _notes,
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.notes, size: 16),
                      label: Text(tr('В сносках', 'In notes')),
                      onSelected: (v) => setState(() {
                        _notes = v;
                        if (_hits.isNotEmpty) _run();
                      }),
                    ),
                  ),
                ),
                // Переключатель вида: плоский список / аккордеон книг.
                if (_hits.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SegmentedButton<SearchResultsView>(
                      segments: [
                        ButtonSegment(
                          value: SearchResultsView.list,
                          icon: const Icon(Icons.view_list, size: 16),
                          label: Text(tr('Список', 'List')),
                        ),
                        ButtonSegment(
                          value: SearchResultsView.books,
                          icon: const Icon(
                            Icons.account_tree_outlined,
                            size: 16,
                          ),
                          label: Text(tr('По книгам', 'By books')),
                        ),
                      ],
                      selected: {_view},
                      onSelectionChanged: (s) =>
                          setState(() => _view = s.first),
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          // Счётчик результатов: «Найдено: N», а при усечении лимитом —
          // «100+» (запрос отдаёт не больше _searchLimit).
          if (!_busy && _hits.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  _hits.length >= _searchLimit
                      ? tr(
                          'Найдено: $_searchLimit+ (показаны первые)',
                          'Found: $_searchLimit+ (first shown)',
                        )
                      : tr(
                          'Найдено: ${_hits.length}',
                          'Found: ${_hits.length}',
                        ),
                  style: TextStyle(fontSize: 13, color: p.muted),
                ),
              ),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_notice!, style: TextStyle(color: p.muted)),
            ),
          Expanded(
            child: _view == SearchResultsView.books
                ? _booksView(p)
                : ListView.builder(
                    itemCount: _hits.length,
                    itemBuilder: (context, i) => _hitTile(p, _hits[i]),
                  ),
          ),
        ],
      ),
    );
  }

  /// Один результат поиска — ссылка «Книга Гл:Ст» и сниппет.
  Widget _hitTile(Palette p, SearchHit h) {
    final book = bookShort(h.book);
    return ListTile(
      dense: true,
      title: Text(
        '$book ${h.chapter}:${h.verse}',
        style: TextStyle(fontWeight: FontWeight.w600, color: p.accent),
      ),
      subtitle: Text(
        h.snippet,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.ink),
      ),
      onTap: _openHit(h),
    );
  }

  VoidCallback? _openHit(SearchHit h) => widget.onOpenVerse != null
      ? () => widget.onOpenVerse!(_moduleId, h.book, h.chapter, h.verse)
      : () => Navigator.of(context).push(
          fastRoute(
            ReadingScreen(
              bookCode: h.book,
              chapter: h.chapter,
              verse: h.verse,
              moduleId: _moduleId,
            ),
          ),
        );

  /// Режим «По книгам»: аккордеон «Название · N»; внутри книги —
  /// плоские совпадения, отсортированные по главе и стиху (канон).
  /// Книги — в каноническом порядке, вне каталога — в конце по
  /// порядку появления.
  Widget _booksView(Palette p) {
    final byBook = <String, List<SearchHit>>{};
    for (final h in _hits) {
      byBook.putIfAbsent(h.book, () => []).add(h);
    }
    final books = byBook.keys.toList()
      ..sort((a, b) {
        final ia = bookIndexOf(a);
        final ib = bookIndexOf(b);
        if (ia < 0 && ib < 0) return 0;
        if (ia < 0) return 1;
        if (ib < 0) return -1;
        return ia - ib;
      });
    for (final hits in byBook.values) {
      hits.sort(
        (a, b) =>
            a.chapter != b.chapter ? a.chapter - b.chapter : a.verse - b.verse,
      );
    }
    return ListView(
      children: [
        for (final code in books)
          ExpansionTile(
            key: PageStorageKey('search-book-$code'),
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.only(bottom: 4),
            dense: true,
            initiallyExpanded: _expanded.contains(code),
            onExpansionChanged: (v) => setState(
              () => v ? _expanded.add(code) : _expanded.remove(code),
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    bookFull(code),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Счётчик совпадений — пилюля, чтобы не сливался
                // с названием книги.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${byBook[code]!.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: p.accent,
                    ),
                  ),
                ),
              ],
            ),
            children: [
              for (final h in byBook[code]!)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _hitTile(p, h),
                ),
            ],
          ),
      ],
    );
  }
}
