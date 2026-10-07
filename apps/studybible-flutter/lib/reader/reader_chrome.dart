part of '../screens/reading_screen.dart';

/// Панели и элементы управления экрана чтения.
extension _ReaderChrome on _ReadingScreenState {
  /// Флаги слоёв по id вклада (ADR 0020): реестр задаёт порядок и
  /// доступность, настройки хранят состояние. Неизвестный id — мягкий
  /// пропуск (слой неизвестного плагина в сохранённой раскладке).
  bool _layerFlag(String id) => switch (id) {
    'layer.footnotes' => settings.layerFootnotes,
    'layer.xrefs' => settings.layerXrefs,
    'layer.strongs' => settings.layerStrongs,
    _ => false,
  };

  void _setLayerFlag(String id, bool v) => switch (id) {
    'layer.footnotes' => settings.layerFootnotes = v,
    'layer.xrefs' => settings.layerXrefs = v,
    'layer.strongs' => settings.layerStrongs = v,
    _ => null,
  };

  List<Widget> _toolActions(
    Palette p, {
    bool search = true,
    bool large = false,
  }) {
    final double sz = large ? 27 : 20;
    // Понятный свой цвет на действие (нижняя мобильная панель).
    Color cc(bool on, Color fixed) => on ? p.accent : (large ? fixed : p.muted);
    const cTranslate = Color(0xFF5C6BC0); // indigo
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
            // Смена перевода на месте — переход: «назад» возвращает
            // прежний перевод (ADR 0019).
            workspace.go(
              Location.verse(
                moduleId: v,
                book: _code,
                chapter: _ch,
                verse: _selectedVerse ?? 0,
                pane: _paneSnapshot(),
              ),
            );
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
          if (_interleaved) _initCompareModules();
          workspace.updateSnapshot(_paneSnapshot());
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
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Плавающее поле поиска над нижней панелью (мобильная раскладка):
  /// не закрывает экран, клавиатура поднимается поверх. Enter или
  /// кнопка-стрелка — переход на экран результатов с запросом.
  Widget _searchField(Palette p) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: 12,
      right: 12,
      // Над нижней панелью (инсет + высота кнопок ~66) и над
      // мини-плеером TTS, если он есть.
      bottom: bottomInset + 66 + (_ttsPlaying ? 64 : 0),
      child: Material(
        color: p.card,
        elevation: 6,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: p.muted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(fontSize: 14, color: p.ink),
                  decoration: InputDecoration(
                    hintText: tr('Поиск по тексту', 'Search the text'),
                    hintStyle: TextStyle(color: p.muted),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _openSearch(),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, size: 18, color: p.muted),
                tooltip: tr('Закрыть', 'Close'),
                onPressed: () => _rebuild(() => _searchOpen = false),
              ),
              IconButton(
                icon: Icon(Icons.arrow_forward, size: 18, color: p.accent),
                tooltip: tr('Искать', 'Search'),
                onPressed: _openSearch,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSearch() {
    final q = _searchCtrl.text.trim();
    _rebuild(() => _searchOpen = false);
    Navigator.of(context).push(
      fastRoute(
        SearchScreen(
          moduleId: _moduleId,
          initialQuery: q.isEmpty ? null : q,
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
              btn(
                Icons.search,
                tr('Поиск', 'Search'),
                _searchOpen,
                () {
                  _rebuild(() {
                    _searchOpen = !_searchOpen;
                    if (!_searchOpen) _searchCtrl.clear();
                  });
                  // Поле вставлено в этот же кадр — autofocus на
                  // Android часто не поднимает клавиатуру; просим
                  // фокус явно, когда виджет уже на дереве.
                  if (_searchOpen) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _searchFocus.requestFocus(),
                    );
                  }
                },
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
                  workspace.go(
                    Location.verse(
                      moduleId: e.key,
                      book: _code,
                      chapter: _ch,
                      verse: _selectedVerse ?? 0,
                      pane: _paneSnapshot(),
                    ),
                  );
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
                  tr('Подстрочное сравнение', 'Interleaved compare'),
                  tr('Второй перевод под каждым стихом', 'Second line per verse'),
                  _interleaved,
                  (v) => _rebuild(() {
                    _interleaved = v;
                    if (v) {
                      _compare = false;
                      _initCompareModules();
                    }
                    workspace.updateSnapshot(_paneSnapshot());
                  }),
                ),
                if (_interleaved)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('Переводы сравнения:', 'Compare translations:'),
                          style: TextStyle(fontSize: 13, color: p.muted),
                        ),
                        const SizedBox(height: 6),
                        _interleavedPicker(p),
                      ],
                    ),
                  )
                else if (_compare)
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
                // Слои-флаги перебираются из реестра вкладов (ADR 0020):
                // порядок и фильтр requires — у реестра, состояние — у
                // настроек. `layer.compare` обработан выше отдельно.
                for (final c in contributions
                    .ofKind(ContributionKind.layer)
                    .where((c) => c.id != 'layer.compare'))
                  if (c.availableFor(_module))
                    sw(c.title, c.subtitle, _layerFlag(c.id), (v) {
                      settings.update(() => _setLayerFlag(c.id, v));
                      setSheet(() {});
                    }),
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
            // Компактные шаги по стеку позиций (ADR 0019); полный
            // журнал без лимита — следующим пунктом.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: tr('Назад', 'Back'),
                    icon: const Icon(Icons.arrow_back, size: 20),
                    onPressed: workspace.canBack
                        ? () {
                            Navigator.of(context).pop();
                            final loc = workspace.back();
                            if (loc != null) _applyLocation(loc);
                          }
                        : null,
                  ),
                  IconButton(
                    tooltip: tr('Вперёд', 'Forward'),
                    icon: const Icon(Icons.arrow_forward, size: 20),
                    onPressed: workspace.canForward
                        ? () {
                            Navigator.of(context).pop();
                            final loc = workspace.forward();
                            if (loc != null) _applyLocation(loc);
                          }
                        : null,
                  ),
                  const Spacer(),
                  Text(
                    '${workspace.depth}',
                    style: TextStyle(fontSize: 11, color: p.muted),
                  ),
                ],
              ),
            ),
            item(Icons.history, tr('История чтения', 'Reading history'), () {
              Navigator.of(context).push(fastRoute(const HistoryScreen()));
            }),
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
              _fontThemeSheet,
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
            bookShort(b.code, b.title),
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

  /// Переход «книга, глава» — переход в стеке рабочего места,
  /// как и свайп (ADR 0019).
  void _jumpTo(String code, int ch) {
    final loc = Location.verse(
      moduleId: _moduleId,
      book: code,
      chapter: ch,
      pane: _paneSnapshot(),
    );
    workspace.go(loc);
    _applyLocation(loc);
  }

  /// Компактный «подпись + ползунок» для листа «Шрифт и тема».
  Widget _miniSlider(String label, double v, void Function(double) set) {
    final p = context.palette;
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: p.muted),
          ),
        ),
        Expanded(
          child: Slider(
            value: v,
            min: 0.8,
            max: 1.6,
            divisions: 8,
            onChanged: set,
          ),
        ),
        Text(
          'x${v.toStringAsFixed(2)}',
          style: TextStyle(fontSize: 11, color: p.muted),
        ),
      ],
    );
  }

  /// Лист «Шрифт и тема» — быстрые настройки чтения без ухода в «Настройки».
  void _fontThemeSheet() {
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListenableBuilder(
          listenable: settings,
          builder: (_, _) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Тема', 'Theme'),
                  style: TextStyle(fontSize: 12, color: p.muted),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AppTheme>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    segments: [
                      ButtonSegment(
                        value: AppTheme.light,
                        label: Text(tr('Светлая', 'Light')),
                      ),
                      ButtonSegment(
                        value: AppTheme.dark,
                        label: Text(tr('Тёмная', 'Dark')),
                      ),
                      const ButtonSegment(
                        value: AppTheme.amoled,
                        label: Text('AMOLED'),
                      ),
                    ],
                    selected: {settings.theme},
                    onSelectionChanged: (s) =>
                        settings.update(() => settings.theme = s.first),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  tr('Шрифт текста', 'Reading font'),
                  style: TextStyle(fontSize: 12, color: p.muted),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ReadingFont>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    segments: [
                      const ButtonSegment(
                        value: ReadingFont.literata,
                        label: Text('Literata'),
                      ),
                      const ButtonSegment(
                        value: ReadingFont.gentium,
                        label: Text('Gentium'),
                      ),
                      const ButtonSegment(
                        value: ReadingFont.ptSerif,
                        label: Text('PT Serif'),
                      ),
                      ButtonSegment(
                        value: ReadingFont.system,
                        label: Text(tr('Сист.', 'System')),
                      ),
                    ],
                    selected: {settings.readingFont},
                    onSelectionChanged: (s) =>
                        settings.update(() => settings.readingFont = s.first),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      tr('Размер', 'Size'),
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                    const Spacer(),
                    Text(
                      'x${settings.fontScale.toStringAsFixed(2)}',
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                  ],
                ),
                Slider(
                  value: settings.fontScale,
                  min: 0.8,
                  max: 1.6,
                  divisions: 8,
                  onChanged: (v) =>
                      settings.update(() => settings.fontScale = v),
                ),
                _miniSlider(
                  tr('Сноски', 'Footnotes'),
                  settings.footScale,
                  (v) => settings.update(() => settings.footScale = v),
                ),
                _miniSlider(
                  tr('Параллельные', 'Cross-refs'),
                  settings.xrefScale,
                  (v) => settings.update(() => settings.xrefScale = v),
                ),
                Text(
                  tr(
                    'Блаженны нищие духом, ибо их есть Царство Небесное.',
                    'Blessed are the poor in spirit, for theirs is the kingdom of heaven.',
                  ),
                  style: TextStyle(
                    fontFamily: readingFontFamily(settings.readingFont),
                    fontSize: 16 * settings.fontScale,
                    color: p.ink,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    buf.write('(${moduleName(_moduleId)})');
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
                        v == null
                            ? ''
                            : tr('стих $v', 'verse $v') + _ttsBackendTag(),
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

  /// Метка активного голосового движка в мини-плеере (ADR 0017):
  /// «· нейро» при sherpa_onnx, «· сист.» при платформенном TTS.
  String _ttsBackendTag() => switch (_ttsService.backendId) {
    'neural' => tr(' · нейро', ' · neural'),
    _ => tr(' · сист.', ' · sys'),
  };

  /// Единый отступ контента под плавающей верхней панелью:
  /// строка состояния + прогресс (2) + ряд кнопок (~48) + зазор.
  double _topClear() => MediaQuery.of(context).padding.top + 56;

  /// Отступ контента над нижней панелью кнопок (узкий экран).
  double _bottomClear() => MediaQuery.of(context).padding.bottom + 62;

  /// Всплывающее меню действий стиха — у места тапа (_lastTapPos).
  /// Порядок: выделить, заметка, закладка, теги, сравнить (5-й),
  /// параллельные, копировать, поделиться.
  Future<void> _verseMenu(int v) async {
    final p = context.palette;
    final chNow = _module?.chapter(_code, _ch);
    final hasNotes = chNow != null && _notesOf(chNow).any((n) => n.verse == v);

    PopupMenuItem<String> mi(String id, IconData i, String l) =>
        PopupMenuItem<String>(
          value: id,
          height: 44,
          child: Row(
            children: [
              Icon(i, size: 18, color: p.muted),
              const SizedBox(width: 10),
              Text(l, style: const TextStyle(fontSize: 14)),
            ],
          ),
        );

    final pos = _lastTapPos;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromCenter(center: pos, width: 1, height: 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 30,
          child: Text(
            tr('ст. $v', 'v. $v'),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: p.accent,
            ),
          ),
        ),
        const PopupMenuDivider(height: 4),
        mi('copy', Icons.copy_outlined, tr('Копировать', 'Copy')),
        mi(
          'hl',
          _highlights.containsKey(v)
              ? Icons.highlight
              : Icons.highlight_outlined,
          tr('Выделить', 'Highlight'),
        ),
        mi(
          'note',
          _verseNotes.containsKey(v)
              ? Icons.sticky_note_2
              : Icons.edit_outlined,
          tr('Заметка', 'Note'),
        ),
        mi(
          'tags',
          _tagEntries.containsKey(v) ? Icons.label : Icons.label_outline,
          tr('Теги', 'Tags'),
        ),
        mi(
          'mark',
          _verseMarks.containsKey(v)
              ? Icons.bookmark
              : Icons.bookmark_outline,
          tr('Закладка', 'Bookmark'),
        ),
        // «Сравнить» — стих во всех переводах (экран; список
        // переводов — в настройках).
        mi('cmp', Icons.compare_arrows, tr('Сравнить', 'Compare')),
        if (hasNotes)
          mi(
            'refs',
            Icons.library_books_outlined,
            tr('Параллельные', 'Cross-refs'),
          ),
        mi('share', Icons.share_outlined, tr('Поделиться', 'Share')),
      ],
    );
    switch (choice) {
      case 'hl':
        _toggleHighlight(v);
      case 'note':
        _editNote(v);
      case 'mark':
        _toggleMark(v);
      case 'tags':
        _editTags(v);
      case 'cmp':
        if (!mounted) return;
        Navigator.of(context).push(
          fastRoute(
            VerseCompareScreen(
              bookCode: _code,
              chapter: _ch,
              verse: v,
              fromVrs: _module?.versification ?? '',
            ),
          ),
        );
      case 'refs':
        _openNotes();
      case 'copy':
        _copyVerse(v);
      case 'share':
        _shareVerse(v);
      case null:
        _rebuild(() => _selectedVerse = null); // тап мимо — снять выбор
    }
  }
}
