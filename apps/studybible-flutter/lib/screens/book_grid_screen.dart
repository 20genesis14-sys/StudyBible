import 'package:flutter/material.dart';

import '../l10n.dart';
import '../data.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import 'chapter_grid_screen.dart';
import '../routes.dart';

/// Сетка 66 книг: непрерывный поток внутри двух разделов,
/// группы выделены только цветом плиток.
class BookGridScreen extends StatefulWidget {
  const BookGridScreen({super.key});

  @override
  State<BookGridScreen> createState() => _BookGridScreenState();
}

class _BookGridScreenState extends State<BookGridScreen> {
  ModuleDoc? _module;

  @override
  void initState() {
    super.initState();
    _reloadModule();
    // Смена основного перевода (чип сверху/настройки) —
    // перезагружаем модуль для имён книг и поиска; смена опции
    // «полные имена» — просто перерисовка.
    settings.addListener(_onSettings);
  }

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    super.dispose();
  }

  void _onSettings() {
    _reloadModule();
    if (mounted) setState(() {});
  }

  String _loadedId = '';
  void _reloadModule() {
    final id = mainModuleId();
    if (id == _loadedId) return;
    _loadedId = id;
    loadModule(id).then((m) {
      if (mounted) setState(() => _module = m);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = MediaQuery.of(context).size.width >= 700;
    final ot = kCatalog.sublist(0, kNtFirstIndex);
    final nt = kCatalog.sublist(kNtFirstIndex);
    // Неполный модуль (напр. только НЗ): книги, которых в нём нет,
    // из сетки прячем — тап на них вёл в пустую главу.
    bool inModule(String code) =>
        _module == null || _module!.bookByCode(code) != null;
    // Опция «полные имена книг» (ADR 0015): имя из модуля,
    // иначе краткое из каталога.
    String nameOf(String code) => settings.bookFullNames
        ? (_module?.bookByCode(code)?.title ?? bookShort(code))
        : (bookShort(code));
    final otVisible = ot
        .where((e) => inModule(e.$1))
        .map((e) => (e.$1, nameOf(e.$1), e.$3))
        .toList();
    final ntVisible = nt
        .where((e) => inModule(e.$1))
        .map((e) => (e.$1, nameOf(e.$1), e.$3))
        .toList();
    // Книги модуля вне каталога 66 (второканонические, напр. в LXX):
    // отдельной секцией внизу сетки.
    final catalogCodes = {for (final e in kCatalog) e.$1};
    final extraVisible = (_module?.books ?? const <BookDoc>[])
        .where((b) => !catalogCodes.contains(b.code))
        .map((b) => (b.code, b.title, BookGroup.other))
        .toList();

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 1200 : double.infinity),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 80 : 16,
                  12,
                  wide ? 80 : 16,
                  0,
                ),
                child: Row(
                  children: [
                    Icon(Icons.translate, size: 16, color: p.muted),
                    const SizedBox(width: 6),
                    Text(
                      tr('Перевод', 'Translation'),
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                    const SizedBox(width: 8),
                    _moduleChip(p),
                  ],
                ),
              ),
            ),

            if (otVisible.isNotEmpty) ...[
              _header(kSectionOt, wide),
              _grid(otVisible, wide),
            ],
            if (ntVisible.isNotEmpty) ...[
              _header(kSectionNt, wide),
              _grid(ntVisible, wide),
            ],
            if (extraVisible.isNotEmpty) ...[
              _header(kSectionOther, wide),
              _grid(extraVisible, wide),
            ],
            SliverToBoxAdapter(child: _legend(wide)),
          ],
        ),
      ),
    );
  }

  Widget _header(String title, bool wide) => SliverPersistentHeader(
    pinned: true,
    delegate: _StickyHeader(
      height: 40,
      child: Container(
        color: context.palette.background,
        padding: EdgeInsets.fromLTRB(wide ? 80 : 16, 12, wide ? 80 : 16, 6),
        alignment: Alignment.bottomLeft,
        child: Text(
          title,
          style: TextStyle(
            fontSize: wide ? 14 : 13,
            fontWeight: FontWeight.w600,
            color: context.palette.ink,
          ),
        ),
      ),
    ),
  );

  Widget _grid(List<(String, String, BookGroup)> books, bool wide) {
    final cols = wide ? 8 : 5;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wide ? 80 : 16, vertical: 8),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: wide ? 12 : 8,
          crossAxisSpacing: wide ? 12 : 8,
          childAspectRatio: wide ? 2.2 : 1.14,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => _BookTile(entry: books[i], wide: wide),
          childCount: books.length,
        ),
      ),
    );
  }

  /// Чип основного перевода на верхней панели вкладки «Библия»:
  /// тап — шторка со списком модулей, выбор сразу действует
  /// (открытые дальше главы пойдут в нём).
  Widget _moduleChip(Palette p) {
    return ListenableBuilder(
      listenable: settings,
      builder: (_, _) {
        final id = mainModuleId();
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _pickModule(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.edge),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    moduleName(id),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.ink,
                    ),
                  ),
                ),
                Icon(Icons.arrow_drop_down, size: 16, color: p.muted),
              ],
            ),
          ),
        );
      },
    );
  }

  void _pickModule(BuildContext context) {
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                tr('Основной перевод', 'Default translation'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.ink,
                ),
              ),
            ),
            // Список прокручивается: модулей уже больше, чем влезает.
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final e in installedModules.entries)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        e.key == mainModuleId()
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        size: 18,
                        color: e.key == mainModuleId() ? p.accent : p.muted,
                      ),
                      title: Text(e.value),
                      onTap: () {
                        Navigator.pop(ctx);
                        settings.update(() => settings.defaultModule = e.key);
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _legend(bool wide) => Padding(
    padding: EdgeInsets.fromLTRB(wide ? 80 : 16, 12, wide ? 80 : 16, 24),
    child: Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        for (final g in BookGroup.values)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: groupColor(g, appThemeOf(context)),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                tr(g.label, g.labelEn),
                style: TextStyle(fontSize: 10, color: context.palette.muted),
              ),
            ],
          ),
      ],
    ),
  );
}

class _BookTile extends StatelessWidget {
  final (String, String, BookGroup) entry;
  final bool wide;
  const _BookTile({required this.entry, required this.wide});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = appThemeOf(context);
    final dark = theme != AppTheme.light;
    return Material(
      color: groupColor(entry.$3, theme),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () =>
            Navigator.of(context)
                .push(fastRoute(ChapterGridScreen(bookCode: entry.$1))),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              entry.$2,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: dark ? p.onAccent : Colors.white,
                fontWeight: FontWeight.w600,
                // Полные имена длиннее — кегль снижаем, но не ниже 11 sp.
                fontSize: wide
                    ? 16
                    : (settings.bookFullNames ? 11.5 : 13),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StickyHeader extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;
  _StickyHeader({required this.height, required this.child});

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(context, shrinkOffset, overlapsContent) => child;

  @override
  bool shouldRebuild(_StickyHeader old) => old.child != child;
}
