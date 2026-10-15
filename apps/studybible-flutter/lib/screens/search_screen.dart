import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../data.dart';
import '../lexicon.dart';
import '../native_bridge.dart' show SearchHit;
import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.js_interop) '../native_bridge_web.dart';
import '../reader/reader_dialogs.dart';
import '../refs.dart';
import '../state.dart';
import '../theme.dart';
import 'reading_screen.dart';
import '../routes.dart';

/// Раздел Библии для быстрой фильтрации выдачи поиска.
enum _SearchScope { all, ot, nt, book }

/// Поиск по тексту модуля (FTS5-индекс ядра; на web — LIKE-фоллбэк).
/// Тап по результату — переход к стиху в текущем переводе.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    this.moduleId,
    this.initialBook,
    this.initialQuery,
    this.onBack,
    this.onOpenVerse,
  });

  /// Модуль, из которого открыли поиск (предвыбор в дрopdown).
  final String? moduleId;

  /// Текущая книга, из которой открыли поиск (для чипа «Эта книга»).
  final String? initialBook;

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
  static const _fetchLimit = 500;
  List<SearchHit> _allHits = const [];
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

  /// Debounce авто-поиска стихов для запроса-Стронга — он однозначен,
  /// поэтому ждать «Найти» не нужно; таймер сглаживает посимвольный ввод.
  Timer? _strongAuto;

  /// Фильтр по разделу канона или текущей книге.
  _SearchScope _scope = _SearchScope.all;

  bool _matchesScope(SearchHit h) => switch (_scope) {
    _SearchScope.all => true,
    _SearchScope.ot =>
      bookIndexOf(h.book) >= 0 && bookIndexOf(h.book) < kNtFirstIndex,
    _SearchScope.nt => bookIndexOf(h.book) >= kNtFirstIndex,
    _SearchScope.book => h.book == widget.initialBook,
  };

  List<SearchHit> get _hits =>
      _allHits.where(_matchesScope).take(_searchLimit).toList();

  bool get _isTruncated =>
      _allHits.where(_matchesScope).length >= _searchLimit;

  Ref? get _directRef => parseQueryRef(_query.text);

  String? get _directStrong {
    final s = _query.text.trim();
    if (s.isEmpty || s.contains(' ')) return null;
    return normalizeStrong(s);
  }

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _query.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  void _openRef(Ref r) {
    history.touchSearch(_query.text.trim());
    if (widget.onOpenVerse != null) {
      widget.onOpenVerse!(_moduleId, r.book, r.chapter, r.verse);
    } else {
      Navigator.of(context).push(
        fastRoute(
          ReadingScreen(
            bookCode: r.book,
            chapter: r.chapter,
            verse: r.verse,
            moduleId: _moduleId,
          ),
        ),
      );
    }
  }

  void _openStrong(String strong) {
    history.touchDict(strong, strong);
    showStrongCard(
      context,
      strong,
      strong,
      modulePath: modulePathOf(_moduleId),
    );
  }

  Future<void> _run({bool fromSubmit = false}) async {
    _strongAuto?.cancel();
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final ref = parseQueryRef(q);
    if (fromSubmit && ref != null) {
      _openRef(ref);
      return;
    }
    history.touchSearch(q);
    setState(() {
      _busy = true;
      _notice = null;
    });
    final path = modulePathOf(_moduleId);
    if (path == null) {
      setState(() {
        _busy = false;
        _allHits = const [];
        _notice = tr(
          'Для этого модуля нет .sb — поиск недоступен.',
          'No .sb for this module — search unavailable.',
        );
      });
      return;
    }
    // Номер Стронга — обратный поиск: все стихи с этим номером
    // (слой `{id}-strongs` или собственная разметка модуля);
    // чип «В сносках» на него не влияет — в сносках Стронга нет.
    final hits = _directStrong != null
        ? await bridgeModuleStrongSearch(path, q, limit: _fetchLimit)
        : _notes
        ? await bridgeNotesSearch(path, q, limit: _fetchLimit)
        : await bridgeModuleSearch(path, q, limit: _fetchLimit);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _allHits = hits;
      _notice = _emptyNotice;
    });
  }

  /// Пояснение к пустой выдаче: для номера Стронга — отдельное
  /// (в переводе может просто не быть разметки), для ссылки омнибокса
  /// пустой список не поясняем — над ним карточка перехода.
  String? get _emptyNotice {
    if (_hits.isNotEmpty || _directRef != null) return null;
    return _directStrong != null
        ? tr(
            'Стихов с $_directStrong не найдено — похоже, в этом переводе нет разметки Стронга.',
            'No verses tagged $_directStrong — this translation may lack Strong’s markup.',
          )
        : tr('Ничего не найдено.', 'Nothing found.');
  }

  @override
  void dispose() {
    _strongAuto?.cancel();
    _query.dispose();
    super.dispose();
  }

  Widget _scopeChip(String label, _SearchScope scope) => ChoiceChip(
    selected: _scope == scope,
    visualDensity: VisualDensity.compact,
    label: Text(label),
    onSelected: (_) => setState(() {
      _scope = scope;
      if (_allHits.isNotEmpty) {
        _notice = _emptyNotice;
      }
    }),
  );

  Widget _omniboxCard(Palette p) {
    final ref = _directRef;
    if (ref != null) {
      final label = '${bookShort(ref.book)} ${ref.chapter}:${ref.verse}';
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Card(
          margin: EdgeInsets.zero,
          color: p.accent.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: p.accent.withValues(alpha: 0.35)),
          ),
          child: ListTile(
            dense: true,
            leading: Icon(Icons.menu_book_outlined, color: p.accent, size: 20),
            title: Text(
              tr('Перейти к $label', 'Go to $label'),
              style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
            ),
            trailing: Icon(Icons.arrow_forward, color: p.accent, size: 18),
            onTap: () => _openRef(ref),
          ),
        ),
      );
    }
    final strong = _directStrong;
    if (strong != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Card(
          margin: EdgeInsets.zero,
          color: p.accent.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: p.accent.withValues(alpha: 0.35)),
          ),
          child: ListTile(
            dense: true,
            leading: Icon(Icons.translate, color: p.accent, size: 20),
            title: Text(
              tr(
                'Открыть статью Стронга $strong',
                'Open Strong’s entry $strong',
              ),
              style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
            ),
            subtitle: _allHits.isEmpty
                ? null
                : Text(
                    tr(
                      'Стихи с этим номером — в списке ниже',
                      'Verses with this number are listed below',
                    ),
                    style: TextStyle(fontSize: 12, color: p.muted),
                  ),
            trailing: Icon(Icons.arrow_forward, color: p.accent, size: 18),
            onTap: () => _openStrong(strong),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasBook =
        widget.initialBook != null && widget.initialBook!.isNotEmpty;
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
                        onChanged: (_) {
                          setState(() {});
                          _strongAuto?.cancel();
                          if (_directStrong != null) {
                            _strongAuto = Timer(
                              const Duration(milliseconds: 350),
                              () {
                                if (mounted && _directStrong != null) {
                                  _run();
                                }
                              },
                            );
                          }
                        },
                        onSubmitted: (_) => _run(fromSubmit: true),
                        decoration: InputDecoration(
                          hintText: tr(
                            'Слово, ссылка (Ин 3:16) или Стронг (G3056)…',
                            'Word, ref (Jn 3:16) or Strong’s (G3056)…',
                          ),
                          border: const OutlineInputBorder(),
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 18),
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
                // Фильтры разделов Библии + чип «В сносках».
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _scopeChip(tr('Все', 'All'), _SearchScope.all),
                        _scopeChip(tr('ВЗ', 'OT'), _SearchScope.ot),
                        _scopeChip(tr('НЗ', 'NT'), _SearchScope.nt),
                        if (hasBook)
                          _scopeChip(
                            '${tr('Эта книга', 'This book')} (${bookShort(widget.initialBook!)})',
                            _SearchScope.book,
                          ),
                        FilterChip(
                          selected: _notes,
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.notes, size: 16),
                          label: Text(tr('В сносках', 'In notes')),
                          onSelected: (v) => setState(() {
                            _notes = v;
                            if (_allHits.isNotEmpty) _run();
                          }),
                        ),
                      ],
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
          _omniboxCard(p),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          // Счётчик результатов: «Найдено: N», а при усечении лимитом —
          // «100+» (запрос отдаёт не больше _searchLimit).
          if (!_busy && _hits.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  _isTruncated
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
