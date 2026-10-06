part of '../screens/reading_screen.dart';

/// Панели и элементы управления экрана чтения.
extension _ReaderChrome on _ReadingScreenState {
  List<Widget> _toolActions(
    Palette p, {
    bool search = true,
    bool large = false,
  }) {
    final double sz = large ? 27 : 20;
    // Понятный свой цвет на действие (нижняя мобильная панель).
    Color cc(bool on, Color fixed) => on ? p.accent : (large ? fixed : p.muted);
    const cTranslate = Color(0xFF5C6BC0); // indigo
    const cCompare = Color(0xFF00897B); // teal
    const cInterl = Color(0xFFF9A825); // amber
    const cTts = Color(0xFF43A047); // green
    const cHistory = Color(0xFF8D6E63); // brown
    const cNotes = Color(0xFF7E57C2); // purple
    return [
      PopupMenuButton<String>(
        tooltip: tr('Перевод', 'Translation'),
        icon: Icon(Icons.translate, size: sz, color: cc(false, cTranslate)),
        onSelected: (v) {
          _stopTts();
          // Откладываем смену на кадр после закрытия попапа: перестройка
          // главы в том же кадре оставляла зависший барьер меню на web.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _rebuild(() => _moduleId = v);
            // Подгружает модуль и текущую главу (лениво через мост).
            _load(v);
            _loadVerseEntries();
            history.touch(v, _code, _ch);
          });
        },
        itemBuilder: (_) => [
          for (final e in kModules.entries)
            PopupMenuItem(
              value: e.key,
              child: Row(
                children: [
                  if (e.key == _moduleId)
                    Icon(Icons.check, size: 16, color: p.accent)
                  else
                    const SizedBox(width: 16),
                  const SizedBox(width: 8),
                  Text(e.value),
                ],
              ),
            ),
        ],
      ),
      IconButton(
        tooltip: tr('Сравнить переводы', 'Compare translations'),
        icon: Icon(
          Icons.compare_arrows,
          size: sz,
          color: cc(_compare, cCompare),
        ),
        onPressed: () {
          _rebuild(() {
            _compare = !_compare;
            if (_compare) _interleaved = false;
          });
          // Вторую панель сравнения подгружаем лениво.
          final second = _mods[_compareModuleId];
          if (_compare && second != null) {
            _ensureChapter(second, _code, _ch);
          }
          // Сразу выравниваем вторую панель по текущему месту
          // первой — иначе она открывается с начала главы.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_compare) _syncScroll(_scroll, _compareScroll);
          });
        },
      ),
      IconButton(
        tooltip: tr('Строчное сравнение', 'Line-by-line compare'),
        icon: Icon(
          Icons.view_day_outlined,
          size: sz,
          color: cc(_interleaved, cInterl),
        ),
        onPressed: () {
          _rebuild(() {
            _interleaved = !_interleaved;
            if (_interleaved) _compare = false;
          });
          final second = _mods[_compareModuleId];
          if (_interleaved && second != null) {
            _ensureChapter(second, _code, _ch);
          }
        },
      ),
      IconButton(
        tooltip: _ttsPlaying
            ? tr('Стоп', 'Stop')
            : tr('Читать вслух', 'Read aloud'),
        icon: Icon(
          _ttsPlaying ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
          size: sz,
          color: cc(_ttsPlaying, cTts),
        ),
        onPressed: _toggleTts,
      ),
      if (search)
        IconButton(
          tooltip: tr('Поиск', 'Search'),
          icon: Icon(Icons.search, size: sz, color: p.muted),
          onPressed: () =>
              Navigator.of(context)
                  .push(fastRoute(SearchScreen(moduleId: _moduleId))),
        ),
      IconButton(
        tooltip: tr('История чтения', 'Reading history'),
        icon: Icon(Icons.history, size: sz, color: cc(false, cHistory)),
        onPressed: () =>
            Navigator.of(context).push(fastRoute(const HistoryScreen())),
      ),
      IconButton(
        tooltip: tr('Сноски', 'Footnotes'),
        icon: Icon(Icons.notes, size: sz, color: cc(_notesOpen, cNotes)),
        onPressed: _openNotes,
      ),
    ];
  }

  /// Переключатель «Чтение / Изучение» (ADR 0015): компактная
  /// двухсегментная пилюля в верхней панели.
  Widget _modeSwitch(Palette p) {
    Widget seg(String label, ReaderMode m) {
      final on = settings.readerMode == m;
      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: on
            ? null
            : () => settings.update(() => settings.readerMode = m),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: on ? p.accent.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              color: on ? p.accent : p.muted,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.edge.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(tr('Чтение', 'Read'), ReaderMode.reading),
          seg(tr('Изучение', 'Study'), ReaderMode.study),
        ],
      ),
    );
  }

  Widget _topBar(Palette p, Color color, {required bool wide}) {
    // Фон панели рисуем ПОД строкой состояния (edge-to-edge), а
    // содержимое опускаем на её высоту — иначе над панелью остаётся
    // щель, где просвечивает «голый» прокручиваемый текст.
    final topInset = MediaQuery.of(context).padding.top;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: _ReadingScreenState._glassBlur,
          sigmaY: _ReadingScreenState._glassBlur,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: p.card.withValues(alpha: _ReadingScreenState._glassAlpha),
            border: Border(
              bottom: BorderSide(color: _ReadingScreenState._glassRim(p)),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: topInset),
              _scrollProgress(color),
              Row(
                children: [
                  IconButton(
                    tooltip: tr('Назад', 'Back'),
                    icon: Icon(Icons.arrow_back, color: p.muted),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Название книги короткое (~12 знаков + …) — длинные
                  // имена не выталкивают поисковую пилюлю за экран.
                  // Flexible loose: заголовок может сжаться до нуля,
                  // пилюля при этом всегда целиком на экране.
                  Flexible(
                    // Тап по «Книга Гл. ▾» — быстрый переход
                    // книга → глава (ADR 0015).
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _quickNav,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                '${_titleCapped()} $_ch',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.expand_more,
                              size: 16,
                              color: p.muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (wide) ...[
                    IconButton(
                      tooltip: tr('Предыдущая глава', 'Previous chapter'),
                      icon: Icon(Icons.chevron_left, color: p.muted),
                      onPressed: () => _go(-1),
                    ),
                    IconButton(
                      tooltip: tr('Следующая глава', 'Next chapter'),
                      icon: Icon(Icons.chevron_right, color: p.muted),
                      onPressed: () => _go(1),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _modeSwitch(p),
                              const SizedBox(width: 6),
                              ..._toolActions(p),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ] else ...[
                    const Spacer(),
                    _modeSwitch(p),
                    _searchPill(p),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Поле-пилюля «Поиск…» в верхней панели: тап открывает экран
  /// поиска по текущему модулю.
  Widget _searchPill(Palette p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () =>
            Navigator.of(context)
                .push(fastRoute(SearchScreen(moduleId: _moduleId))),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: p.edge.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 17, color: p.muted),
              const SizedBox(width: 8),
              Text(
                tr('Поиск по тексту', 'Search the text'),
                style: TextStyle(fontSize: 13, color: p.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Полоса прокрутки главы (была в AppBar).
  Widget _scrollProgress(Color color) {
    return ListenableBuilder(
      listenable: _scroll,
      builder: (_, _) {
        final ready =
            _scroll.hasClients &&
            _scroll.positions.length == 1 &&
            _scroll.position.hasContentDimensions;
        final max = ready ? _scroll.position.maxScrollExtent : 0.0;
        final off = ready ? _scroll.position.pixels : 0.0;
        return LinearProgressIndicator(
          value: max > 0 ? (off / max).clamp(0.0, 1.0) : 0.0,
          minHeight: 2,
          backgroundColor: Colors.transparent,
          valueColor: AlwaysStoppedAnimation(color.withValues(alpha: 0.6)),
        );
      },
    );
  }

  /// Нижняя панель чтения (ADR 0015): 4 монохромные кнопки
  /// Перевод · Слои · Слушать · Ещё. Вместо размытия за панелью —
  /// градиент фона, текст «уходит в бумагу».
  Widget _controlBar(Palette p, Color color, {required bool wide}) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    Widget btn(IconData icon, String label, bool on, VoidCallback f) {
      final c = on ? p.accent : p.muted;
      return Expanded(
        child: InkWell(
          onTap: f,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: c),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(fontSize: 11, color: c)),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Градиент фона вместо «стекла» за панелью (ADR 0015).
        Container(
          height: 22,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                p.background.withValues(alpha: 0),
                p.background.withValues(alpha: 0.92),
              ],
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: p.card,
            border: Border(top: BorderSide(color: p.edge)),
          ),
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Row(
            children: [
              btn(
                Icons.translate,
                tr('Перевод', 'Version'),
                false,
                _translationSheet,
              ),
              btn(
                Icons.layers_outlined,
                tr('Слои', 'Layers'),
                _compare || _interleaved,
                _layersSheet,
              ),
              btn(
                _ttsPlaying
                    ? Icons.stop_circle_outlined
                    : Icons.volume_up_outlined,
                tr('Слушать', 'Listen'),
                _ttsPlaying,
                () => _toggleTts(),
              ),
              btn(Icons.more_horiz, tr('Ещё', 'More'), false, _moreSheet),
            ],
          ),
        ),
      ],
    );
  }

  /// Лист выбора перевода (кнопка «Перевод» нижней панели).
  void _translationSheet() {
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final e in kModules.entries)
              ListTile(
                dense: true,
                leading: e.key == _moduleId
                    ? Icon(Icons.check, size: 18, color: p.accent)
                    : const SizedBox(width: 18),
                title: Text(e.value),
                onTap: () {
                  Navigator.of(context).pop();
                  _stopTts();
                  _rebuild(() => _moduleId = e.key);
                  _load(e.key);
                  _loadVerseEntries();
                  history.touch(e.key, _code, _ch);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Лист «Слои» (ADR 0015): сравнение, подстрочник и учебные
  /// метки — переключатели. Маркеры видны в режиме «Изучение».
  void _layersSheet() {
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget sw(
            String label,
            String hint,
            bool value,
            void Function(bool) set,
          ) => SwitchListTile(
            dense: true,
            title: Text(label, style: const TextStyle(fontSize: 14)),
            subtitle: hint.isEmpty
                ? null
                : Text(hint, style: TextStyle(fontSize: 12, color: p.muted)),
            value: value,
            onChanged: (v) {
              set(v);
              setSheet(() {});
            },
          );
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    tr('Слои', 'Layers'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                ),
                sw(
                  tr('Сравнение переводов', 'Compare translations'),
                  tr('Вторая колонка/панель', 'Second pane'),
                  _compare,
                  (v) => _rebuild(() {
                    _compare = v;
                    if (v) {
                      _interleaved = false;
                      final m = _mods[_compareModuleId];
                      if (m != null) _ensureChapter(m, _code, _ch);
                    }
                  }),
                ),
                sw(
                  tr('Подстрочное сравнение', 'Interleaved compare'),
                  tr('Второй перевод под каждым стихом', 'Second line per verse'),
                  _interleaved,
                  (v) => _rebuild(() {
                    _interleaved = v;
                    if (v) {
                      _compare = false;
                      final m = _mods[_compareModuleId];
                      if (m != null) _ensureChapter(m, _code, _ch);
                    }
                  }),
                ),
                if (_compare || _interleaved)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text(
                          tr('Второй перевод:', 'Second translation:'),
                          style: TextStyle(fontSize: 13, color: p.muted),
                        ),
                        const SizedBox(width: 12),
                        _comparePicker(p),
                      ],
                    ),
                  ),
                const Divider(),
                sw(
                  tr('Сноски', 'Footnotes'),
                  '',
                  settings.layerFootnotes,
                  (v) => settings.update(() => settings.layerFootnotes = v),
                ),
                sw(
                  tr('Параллельные места', 'Cross-references'),
                  '',
                  settings.layerXrefs,
                  (v) => settings.update(() => settings.layerXrefs = v),
                ),
                sw(
                  tr('Номера Стронга', 'Strong’s numbers'),
                  '',
                  settings.layerStrongs,
                  (v) => settings.update(() => settings.layerStrongs = v),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    tr(
                      'Метки отображаются в режиме «Изучение».',
                      'Marks are shown in Study mode.',
                    ),
                    style: TextStyle(fontSize: 12, color: p.muted),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Меню «Ещё» (ADR 0015): история, переход к стиху, вёрстка,
  /// закладка главы, копировать главу, шрифт и тема.
  void _moreSheet() {
    final p = context.palette;
    Widget item(IconData i, String l, VoidCallback f) => ListTile(
      dense: true,
      leading: Icon(i, size: 20, color: p.muted),
      title: Text(l, style: const TextStyle(fontSize: 14)),
      onTap: () {
        Navigator.of(context).pop();
        f();
      },
    );
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            item(Icons.history, tr('История чтения', 'Reading history'), () {
              Navigator.of(context).push(fastRoute(const HistoryScreen()));
            }),
            item(
              Icons.my_location_outlined,
              tr('Перейти к стиху…', 'Go to verse…'),
              _gotoVerseDialog,
            ),
            item(
              Icons.view_agenda_outlined,
              tr('Вёрстка', 'Layout'),
              _layoutSheet,
            ),
            item(
              Icons.bookmark_add_outlined,
              tr('Закладка на главу', 'Bookmark chapter'),
              _bookmarkChapter,
            ),
            item(
              Icons.copy_outlined,
              tr('Копировать главу', 'Copy chapter'),
              _copyChapter,
            ),
            item(
              Icons.text_fields,
              tr('Шрифт и тема', 'Font and theme'),
              () => Navigator.of(
                context,
              ).push(fastRoute(const SettingsScreen())),
            ),
          ],
        ),
      ),
    );
  }

  /// Выбор вёрстки главы — из меню «Ещё».
  void _layoutSheet() {
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (m, ru, en) in [
              (LayoutMode.paragraphs, 'Абзацы', 'Paragraphs'),
              (LayoutMode.versePerLine, 'Стих на строку', 'Verse per line'),
              (LayoutMode.book, 'Книга лентой', 'Book feed'),
            ])
              ListTile(
                dense: true,
                leading: settings.layoutMode == m
                    ? Icon(Icons.check, size: 18, color: p.accent)
                    : const SizedBox(width: 18),
                title: Text(tr(ru, en)),
                onTap: () {
                  Navigator.of(context).pop();
                  settings.update(() => settings.layoutMode = m);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Быстрый переход по тапу на заголовок: книга → глава (ADR 0015).
  void _quickNav() {
    final p = context.palette;
    final books = _module?.books ?? const <BookDoc>[];
    String? sel;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.62,
            child: sel == null
                ? Builder(
                    builder: (_) {
                      // Разделы как в каталоге: ВЗ → НЗ → прочие
                      // (книги модуля вне канона-66, напр. LXX).
                      final ot = <BookDoc>[], nt = <BookDoc>[], ex = <BookDoc>[];
                      for (final b in books) {
                        final idx = kCatalog.indexWhere((e) => e.$1 == b.code);
                        if (idx < 0) {
                          ex.add(b);
                        } else if (idx < kNtFirstIndex) {
                          ot.add(b);
                        } else {
                          nt.add(b);
                        }
                      }
                      return ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          for (final (label, list) in [
                            (tr('Ветхий Завет', 'Old Testament'), ot),
                            (tr('Новый Завет', 'New Testament'), nt),
                            (tr('Прочие книги', 'Other books'), ex),
                          ])
                            if (list.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  2, 4, 2, 8,
                                ),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: p.muted,
                                  ),
                                ),
                              ),
                              GridView.count(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                crossAxisCount:
                                    MediaQuery.of(ctx).size.width >= 700
                                    ? 8
                                    : 4,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                childAspectRatio: 1.9,
                                children: [
                                  for (final b in list)
                                    _bookTile(ctx, p, b, () {
                                      if (b.chapters <= 1) {
                                        Navigator.of(ctx).pop();
                                        _jumpTo(b.code, 1);
                                      } else {
                                        setSheet(() => sel = b.code);
                                      }
                                    }),
                                ],
                              ),
                              const SizedBox(height: 10),
                            ],
                        ],
                      );
                    },
                  )
                : Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back, size: 20),
                            onPressed: () => setSheet(() => sel = null),
                          ),
                          Expanded(
                            child: Text(
                              _titleOf(sel!),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        child: GridView.count(
                          // Плотнее: клетка главы ~вдвое меньше
                          // (десктоп 12, телефон 8 в строке).
                          crossAxisCount:
                              MediaQuery.of(ctx).size.width >= 700 ? 12 : 8,
                          childAspectRatio: 1.2,
                          padding: const EdgeInsets.all(12),
                          children: [
                            for (var i = 1;
                                i <=
                                    (books
                                        .firstWhere((b) => b.code == sel)
                                        .chapters);
                                i++)
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  _jumpTo(sel!, i);
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: sel == _code && i == _ch
                                        ? p.accent.withValues(alpha: 0.16)
                                        : null,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: p.edge),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '$i',
                                    style: TextStyle(
                                      fontWeight: sel == _code && i == _ch
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                      color: sel == _code && i == _ch
                                          ? p.accent
                                          : p.ink,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// Плитка книги в листе быстрого перехода: цвет группы (как в
  /// разделе «Библия»), рамка у текущей книги.
  Widget _bookTile(BuildContext ctx, Palette p, BookDoc b, VoidCallback onTap) {
    final group = kCatalog
        .where((e) => e.$1 == b.code)
        .map((e) => e.$3)
        .firstOrNull;
    final theme = appThemeOf(context);
    final cur = b.code == _code;
    return Material(
      color: group != null ? groupColor(group, theme) : p.card,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: cur ? Border.all(color: p.onAccent, width: 2.5) : null,
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Text(
            kShortName[b.code] ?? b.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: group == null || theme != AppTheme.light
                  ? p.onAccent
                  : Colors.white,
              fontSize: 12,
              fontWeight: cur ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  /// Переход «книга, глава» — тот же сброс состояния, что у _go.
  void _jumpTo(String code, int ch) {
    _stopTts();
    _rebuild(() {
      _code = code;
      _ch = ch;
      _selectedVerse = null;
      _notesOpen = false;
      _blockKeys.clear();
      _bookVerseKeys.clear();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    progress.markRead(code, ch);
    progress.setPosition(code, ch);
    history.touch(_moduleId, code, ch);
    _loadVerseEntries();
    for (final m in _mods.values) {
      _ensureChapter(m, code, ch);
    }
  }

  /// Диалог «Перейти к стиху…» — номер стиха текущей главы.
  Future<void> _gotoVerseDialog() async {
    final ctrl = TextEditingController();
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Перейти к стиху', 'Go to verse')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: '${_titleOf(_code)} $_ch:N',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (t) => Navigator.of(ctx).pop(int.tryParse(t)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(int.tryParse(ctrl.text)),
            child: Text(tr('Перейти', 'Go')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final max = _module?.verseCount(_code, _ch) ?? 0;
    if (v == null || v < 1 || v > max) return;
    _rebuild(() => _selectedVerse = v);
    progress.setVerse(_code, _ch, v);
    _scrollToVerse(v);
  }

  /// Закладка на главу целиком — mark-запись с verse=0.
  Future<void> _bookmarkChapter() async {
    await bridgeEntryAdd(
      kind: 'mark',
      module: _moduleId,
      book: _code,
      chapter: _ch,
      verse: 0,
      text: '',
      context: '${_titleOf(_code)} $_ch',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Закладка добавлена', 'Bookmark added')),
        ),
      );
    }
  }

  /// Плоский текст главы в буфер обмена.
  Future<void> _copyChapter() async {
    final ch = _module?.chapter(_code, _ch);
    if (ch == null) return;
    final verses = _plainVerses(ch);
    final buf = StringBuffer('${_titleOf(_code)} $_ch\n\n');
    for (final e in verses.entries) {
      buf.writeln('${e.key} ${e.value}');
    }
    buf.write('(${kModules[_moduleId] ?? _moduleId})');
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Глава скопирована', 'Chapter copied'))),
      );
    }
  }

  /// Мини-плеер чтения вслух: «стих N», ‹ › перемотка по стихам,
  /// пауза/продолжить, стоп и ползунок прогресса по стихам главы
  /// (перетаскиваемый). Та же «стеклянная» заливка, что у
  /// верхней и нижней панелей.
  Widget _ttsPlayer(Palette p) {
    final len = _ttsList.length;
    // Пока ползунок тащат — показываем стих под пальцем.
    final shown = len == 0 ? 0 : (_ttsDrag ?? _ttsIndex).clamp(0, len - 1);
    final v = len == 0 ? _ttsVerse : _ttsList[shown].key;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: _ReadingScreenState._glassBlur,
          sigmaY: _ReadingScreenState._glassBlur,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: p.card.withValues(alpha: _ReadingScreenState._glassAlpha),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: _ReadingScreenState._glassRim(p)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 46,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: tr('Предыдущий стих', 'Previous verse'),
                      icon: Icon(Icons.skip_previous, color: p.muted),
                      onPressed: _ttsIndex > 0 ? () => _seekTts(-1) : null,
                    ),
                    IconButton(
                      tooltip: _ttsPaused
                          ? tr('Продолжить', 'Resume')
                          : tr('Пауза', 'Pause'),
                      icon: Icon(
                        _ttsPaused ? Icons.play_arrow : Icons.pause,
                        color: p.accent,
                        size: 28,
                      ),
                      onPressed: _ttsPaused ? _resumeTts : _pauseTts,
                    ),
                    IconButton(
                      tooltip: tr('Следующий стих', 'Next verse'),
                      icon: Icon(Icons.skip_next, color: p.muted),
                      onPressed: _ttsIndex < len - 1 ? () => _seekTts(1) : null,
                    ),
                    Expanded(
                      child: Text(
                        v == null ? '' : tr('стих $v', 'verse $v'),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: p.muted),
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Стоп', 'Stop'),
                      icon: Icon(Icons.stop, color: p.jesus),
                      onPressed: _stopTts,
                    ),
                  ],
                ),
              ),
              if (len > 1)
                SizedBox(
                  height: 18,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                    ),
                    child: Slider(
                      value: shown.toDouble(),
                      max: (len - 1).toDouble(),
                      onChanged: (x) => _rebuild(() => _ttsDrag = x.round()),
                      onChangeEnd: (x) {
                        final i = x.round();
                        _ttsDrag = null;
                        _slideTts(i);
                      },
                    ),
                  ),
                ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  /// Единый отступ контента под плавающей верхней панелью:
  /// строка состояния + прогресс (2) + ряд кнопок (~48) + зазор.
  double _topClear() => MediaQuery.of(context).padding.top + 56;

  /// Отступ контента над нижней панелью кнопок (узкий экран).
  double _bottomClear() => MediaQuery.of(context).padding.bottom + 62;

  Widget _actionBar(Palette p) {
    Widget btn(IconData i, String l, VoidCallback f) => TextButton.icon(
      onPressed: f,
      icon: Icon(i, size: 16),
      label: Text(l, style: const TextStyle(fontSize: 12)),
    );
    final v = _selectedVerse!;
    // У выделенного стиха есть сноски/параллельные — показываем
    // явную кнопку (жалоба: тап по «×» в тексте не очевиден).
    final chNow = _module?.chapter(_code, _ch);
    final hasNotes = chNow != null && _notesOf(chNow).any((n) => n.verse == v);

    return Material(
      color: p.card,
      elevation: 8,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Text(
                        tr('ст. $_selectedVerse', 'v. $_selectedVerse'),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: p.accent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      btn(
                        _highlights.containsKey(v)
                            ? Icons.highlight
                            : Icons.highlight_outlined,
                        tr('Выделить', 'Highlight'),
                        () => _toggleHighlight(v),
                      ),
                      btn(
                        _verseNotes.containsKey(v)
                            ? Icons.sticky_note_2
                            : Icons.edit_outlined,
                        tr('Заметка', 'Note'),
                        () => _editNote(v),
                      ),
                      btn(
                        _verseMarks.containsKey(v)
                            ? Icons.bookmark
                            : Icons.bookmark_outline,
                        tr('Закладка', 'Bookmark'),
                        () => _toggleMark(v),
                      ),
                      btn(
                        _tagEntries.containsKey(v)
                            ? Icons.label
                            : Icons.label_outline,
                        tr('Теги', 'Tags'),
                        () => _editTags(v),
                      ),
                      btn(
                        Icons.copy_outlined,
                        tr('Копировать', 'Copy'),
                        () => _copyVerse(v),
                      ),
                      btn(
                        Icons.share_outlined,
                        tr('Поделиться', 'Share'),
                        () => _shareVerse(v),
                      ),
                      if (hasNotes)
                        btn(
                          Icons.library_books_outlined,
                          tr('Параллельные', 'Cross-refs'),
                          _openNotes,
                        ),
                      btn(Icons.compare_arrows, tr('Сравнить', 'Compare'), () {
                        _rebuild(() => _compare = true);
                        final second = _mods[_compareModuleId];
                        if (second != null) {
                          _ensureChapter(second, _code, _ch);
                        }
                      }),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: tr('Закрыть', 'Close'),
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => _rebuild(() => _selectedVerse = null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
