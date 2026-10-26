part of '../screens/reading_screen.dart';

/// Панели и элементы управления экрана чтения. Хром остаётся на
/// `_ReadingScreenState` (B10 этап 1): нотифаеры баров, поле поиска
/// и стек рабочего места — экранные; панечно-волатильные поля читаются
/// через `pane.` и меняются парой «мутация + pane.rebuild()».
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
    const cSplit = Color(0xFF00897B); // teal
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
            pane._moduleId = v;
            pane.rebuild();
            // Подгружает модуль и текущую главу (лениво через мост).
            pane._load(v);
            pane._loadVerseEntries();
            history.touch(v, pane._code, pane._ch);
            // Смена перевода на месте — переход: «назад» возвращает
            // прежний перевод (ADR 0019).
            workspace.go(
              Location.verse(
                moduleId: v,
                book: pane._code,
                chapter: pane._ch,
                verse: pane._selectedVerse ?? 0,
                pane: pane._paneSnapshot(),
              ),
            );
          });
        },
        itemBuilder: (_) => [
          for (final e in installedModules.entries)
            PopupMenuItem(
              value: e.key,
              child: Row(
                children: [
                  if (e.key == pane._moduleId)
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
          color: cc(pane._interleaved, cInterl),
        ),
        onPressed: () {
          pane._interleaved = !pane._interleaved;
          if (pane._interleaved) pane._compare = false;
          pane.rebuild();
          if (pane._interleaved) pane._initCompareModules();
          workspace.updateSnapshot(pane._paneSnapshot());
        },
      ),
      // Режим «две панели» (B10 этап 2): кнопка только на широком
      // экране (панель управления с ней не рендерится на телефоне).
      // Связь панелей — кнопка в шапке колонки (Icons.link/Icons.link_off),
      // не здесь.
      IconButton(
        tooltip: tr('Две панели', 'Two panes'),
        icon: Icon(Icons.splitscreen, size: sz, color: cc(_split, cSplit)),
        onPressed: _toggleSplit,
      ),
      // Выбор раскладки — пресеты рабочего места (B10 этап 2);
      // на узком экране пункт живёт в листе «Слои».
      IconButton(
        tooltip: tr('Раскладка', 'Layout'),
        icon: Icon(
          Icons.dashboard_customize,
          size: sz,
          color: cc(false, cSplit),
        ),
        onPressed: _presetSheet,
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
          onPressed: () => _openScreen('search', {
            'module': pane._moduleId,
            'book': pane._code,
          }),
        ),
      IconButton(
        tooltip: tr('История чтения', 'Reading history'),
        icon: Icon(Icons.history, size: sz, color: cc(false, cHistory)),
        onPressed: () => _openScreen('history'),
      ),
      IconButton(
        tooltip: tr('Сноски', 'Footnotes'),
        icon: Icon(Icons.notes, size: sz, color: cc(_notesOpen, cNotes)),
        onPressed: _openNotes,
      ),
    ];
  }

  /// Плавающая кнопка «очки» — переключатель «Чтение ↔ Изучение»
  /// (ADR 0015): круглая полупрозрачная плашка справа внизу,
  /// над нижней панелью. В «Изучении» акцентная, в «Чтении» —
  /// приглушённая. Прячется вместе с хромом (`_barVisible`) и под
  /// шторками. Глиф — ассет `assets/icons/glasses.png` (утверждённый
  /// макет; белый на прозрачном, тонируется цветом палитры).
  Widget _glassesFab(Palette p) {
    final study = settings.readerMode == ReaderMode.study;
    return Tooltip(
      message: study
          ? tr('Режим чтения', 'Reading mode')
          : tr('Режим изучения', 'Study mode'),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => settings.update(
            () => settings.readerMode = study
                ? ReaderMode.reading
                : ReaderMode.study,
          ),
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.card,
              border: Border.all(color: p.edge),
            ),
            child: Center(
              child: Image.asset(
                'assets/icons/glasses.png',
                width: 27,
                color: study ? p.accent : p.ink,
                colorBlendMode: BlendMode.srcIn,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Плавающая кнопка «оглавление» — быстрый переход книга → глава:
  /// круглая плашка слева внизу, пара к «очкам» справа (ADR 0015).
  /// Тап повторяет тап по заголовку (`_quickNav`); удержание —
  /// подсказка «Оглавление». Глиф — ассет `assets/icons/book.png`.
  Widget _bookFab(Palette p) {
    return Tooltip(
      message: tr('Оглавление', 'Contents'),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _quickNav,
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.card,
              border: Border.all(color: p.edge),
            ),
            child: Center(
              child: Image.asset(
                'assets/icons/book.png',
                width: 26,
                color: p.ink,
                colorBlendMode: BlendMode.srcIn,
              ),
            ),
          ),
        ),
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
                    // «Назад» в шапке — всегда строго вверх по
                    // иерархии: глава → сетка глав текущей книги
                    // (ROADMAP 1.0.2). Историю позиций обслуживают
                    // только системный жест и стек workspace.
                    onPressed: _hierarchyBack,
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
                  // Полное название книги + глава; под ним мелко —
                  // перевод и режим. Flexible loose: при реальном
                  // переполнении текст режется ellipsis.
                  Flexible(
                    // Тап по «Книга Гл. ▾» — быстрый переход
                    // книга → глава (ADR 0015).
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _quickNav,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    '${pane._titleCapped()} ${pane._ch}',
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
                            Text.rich(
                              // Перевод — нейтральные чернила,
                              // режим — акцент: состояние видно
                              // сразу и перекликается с очками.
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${moduleName(pane._moduleId)} · ',
                                    style: TextStyle(
                                      color: p.ink.withValues(alpha: 0.7),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  TextSpan(
                                    text:
                                        settings.readerMode == ReaderMode.study
                                        ? tr('Изучение', 'Study')
                                        : tr('Чтение', 'Reading'),
                                    style: TextStyle(
                                      color: p.accent,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 10,
                                letterSpacing: 0.3,
                              ),
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
                      onPressed: () => pane._go(-1),
                    ),
                    IconButton(
                      tooltip: tr('Следующая глава', 'Next chapter'),
                      icon: Icon(Icons.chevron_right, color: p.muted),
                      onPressed: () => pane._go(1),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: _toolActions(p),
                          ),
                        ),
                      ),
                    ),
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
  /// Позицию (Positioned) задаёт место вызова; видимость ведёт
  /// нотифаер [_searchOpenN] (ADR 0030).
  Widget _searchField(Palette p) {
    return Material(
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
              onPressed: () => _searchOpenN.value = false,
            ),
            IconButton(
              icon: Icon(Icons.arrow_forward, size: 18, color: p.accent),
              tooltip: tr('Искать', 'Search'),
              onPressed: _openSearch,
            ),
          ],
        ),
      ),
    );
  }

  void _openSearch() {
    final q = _searchCtrl.text.trim();
    _searchOpenN.value = false;
    _openScreen('search', {
      'module': pane._moduleId,
      'book': pane._code,
      if (q.isNotEmpty) 'q': q,
    });
  }

  /// Полоса прокрутки главы (была в AppBar).
  Widget _scrollProgress(Color color) {
    return ListenableBuilder(
      listenable: pane._scroll,
      builder: (_, _) {
        final ready =
            pane._scroll.hasClients &&
            pane._scroll.positions.length == 1 &&
            pane._scroll.position.hasContentDimensions;
        final max = ready ? pane._scroll.position.maxScrollExtent : 0.0;
        final off = ready ? pane._scroll.position.pixels : 0.0;
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
                pane._compare || pane._interleaved,
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
              btn(Icons.search, tr('Поиск', 'Search'), _searchOpen, () {
                // Хром на нотифаере (ADR 0030): текст главы не
                // перестраивается.
                _searchOpenN.value = !_searchOpenN.value;
                if (!_searchOpenN.value) _searchCtrl.clear();
                // Поле вставлено в этот же кадр — autofocus на
                // Android часто не поднимает клавиатуру; просим
                // фокус явно, когда виджет уже на дереве.
                if (_searchOpenN.value) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _searchFocus.requestFocus(),
                  );
                }
              }),
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
            for (final e in installedModules.entries)
              ListTile(
                dense: true,
                leading: e.key == pane._moduleId
                    ? Icon(Icons.check, size: 18, color: p.accent)
                    : const SizedBox(width: 18),
                title: Text(e.value),
                onTap: () {
                  Navigator.of(context).pop();
                  _stopTts();
                  pane._moduleId = e.key;
                  pane.rebuild();
                  pane._load(e.key);
                  pane._loadVerseEntries();
                  history.touch(e.key, pane._code, pane._ch);
                  workspace.go(
                    Location.verse(
                      moduleId: e.key,
                      book: pane._code,
                      chapter: pane._ch,
                      verse: pane._selectedVerse ?? 0,
                      pane: pane._paneSnapshot(),
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
                  tr(
                    'Второй перевод под каждым стихом',
                    'Second line per verse',
                  ),
                  pane._interleaved,
                  (v) {
                    pane._interleaved = v;
                    if (v) {
                      pane._compare = false;
                      pane._initCompareModules();
                    }
                    workspace.updateSnapshot(pane._paneSnapshot());
                    pane.rebuild();
                  },
                ),
                if (pane._interleaved)
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
                        pane._interleavedPicker(context, p),
                      ],
                    ),
                  )
                else if (pane._compare)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text(
                          tr('Второй перевод:', 'Second translation:'),
                          style: TextStyle(fontSize: 13, color: p.muted),
                        ),
                        const SizedBox(width: 12),
                        pane._comparePicker(p),
                      ],
                    ),
                  ),
                const Divider(),
                // Слои-флаги перебираются из реестра вкладов (ADR 0020):
                // порядок и фильтр requires — у реестра, состояние — у
                // настроек. `layer.compare` обработан выше отдельно.
                for (final c
                    in contributions
                        .ofKind(ContributionKind.layer)
                        .where((c) => c.id != 'layer.compare'))
                  if (c.availableFor(pane._module))
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
                const Divider(),
                // Раскладка рабочего места (B10 этап 2): на узком
                // экране кнопки в верхней панели нет — пункт здесь.
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.dashboard_customize,
                    size: 20,
                    color: p.muted,
                  ),
                  title: Text(
                    tr('Раскладка', 'Layout'),
                    style: const TextStyle(fontSize: 14),
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    _presetSheet();
                  },
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
              _openScreen('history');
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

  /// Лист «Раскладка» (B10 этап 2): пресеты рабочего места «Чтение/
  /// Сравнение/Места» с одной строкой описания; выбор применяет
  /// пресет ([_applyPreset]). Открывается кнопкой верхней панели
  /// (десктоп) и пунктом листа «Слои» (узкий экран).
  void _presetSheet() {
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                tr('Раскладка', 'Layout'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
            ),
            for (final preset in kWorkspacePresets)
              ListTile(
                dense: true,
                leading: _activePresetId == preset.id
                    ? Icon(Icons.check, size: 18, color: p.accent)
                    : const SizedBox(width: 18),
                title: Text(tr(preset.nameRu, preset.nameEn)),
                subtitle: Text(
                  _presetHint(preset.id),
                  style: TextStyle(fontSize: 12, color: p.muted),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _applyPreset(preset.id);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Одна строка описания пресета раскладки.
  String _presetHint(String id) => switch (id) {
    'reading' => tr('Одна панель во всю ширину', 'One full-width pane'),
    'comparing' => tr(
      'Две панели рядом, листаются вместе',
      'Two panes side by side, in sync',
    ),
    'places' => tr('Две независимые панели', 'Two independent panes'),
    _ => '',
  };

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
    final books = pane._module?.books ?? const <BookDoc>[];
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
                      final ot = <BookDoc>[],
                          nt = <BookDoc>[],
                          ex = <BookDoc>[];
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
                                padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
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
                              pane._titleOf(sel!),
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
                          crossAxisCount: MediaQuery.of(ctx).size.width >= 700
                              ? 12
                              : 8,
                          childAspectRatio: 1.2,
                          padding: const EdgeInsets.all(12),
                          children: [
                            for (
                              var i = 1;
                              i <=
                                  (books
                                      .firstWhere((b) => b.code == sel)
                                      .chapters);
                              i++
                            )
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  _jumpTo(sel!, i);
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: sel == pane._code && i == pane._ch
                                        ? p.accent.withValues(alpha: 0.16)
                                        : null,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: p.edge),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '$i',
                                    style: TextStyle(
                                      fontWeight:
                                          sel == pane._code && i == pane._ch
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                      color: sel == pane._code && i == pane._ch
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
    final cur = b.code == pane._code;
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
      moduleId: pane._moduleId,
      book: code,
      chapter: ch,
      pane: pane._paneSnapshot(),
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
          child: Text(label, style: TextStyle(fontSize: 12, color: p.muted)),
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
                  child: DropdownMenu<ReadingFont>(
                    initialSelection: settings.readingFont,
                    expandedInsets: EdgeInsets.zero,
                    textStyle: const TextStyle(fontSize: 13),
                    onSelected: (f) async {
                      if (f != null && await ensureReadingFontLoaded(f)) {
                        settings.update(() => settings.readingFont = f);
                      }
                    },
                    dropdownMenuEntries: [
                      for (final f in ReadingFont.values.where(
                        (f) => !kRemovedReadingFonts.contains(f),
                      ))
                        DropdownMenuEntry(
                          value: f,
                          label: f == ReadingFont.system
                              ? tr('Системный', 'System')
                              : readingFontLabel(f),
                          style: TextButton.styleFrom(
                            textStyle: TextStyle(
                              fontFamily: readingFontFamily(f),
                              fontSize: 15,
                            ),
                          ),
                        ),
                    ],
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
                const SizedBox(height: 4),
                Text(
                  tr('Насыщенность', 'Weight'),
                  style: TextStyle(fontSize: 12, color: p.muted),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    segments: [
                      ButtonSegment(
                        value: 0,
                        label: Text(tr('Обычн.', 'Regular')),
                      ),
                      ButtonSegment(
                        value: 1,
                        label: Text(tr('Средн.', 'Medium')),
                      ),
                      ButtonSegment(
                        value: 2,
                        label: Text(tr('Полужирн.', 'Semibold')),
                      ),
                      ButtonSegment(
                        value: 3,
                        label: Text(tr('Жирный', 'Bold')),
                      ),
                    ],
                    selected: {settings.fontWeightStep},
                    onSelectionChanged: (s) => settings.update(
                      () => settings.fontWeightStep = s.first,
                    ),
                  ),
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
                    fontWeight: settings.readingWeight,
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
      module: pane._moduleId,
      book: pane._code,
      chapter: pane._ch,
      verse: 0,
      text: '',
      context: '${pane._titleOf(pane._code)} ${pane._ch}',
    );
    // Мутация извещает шину (B8): закладка главы — тоже запись.
    userDataBus.changed(
      module: pane._moduleId,
      book: pane._code,
      chapter: pane._ch,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Закладка добавлена', 'Bookmark added'))),
      );
    }
  }

  /// Плоский текст главы в буфер обмена.
  Future<void> _copyChapter() async {
    final ch = pane._module?.chapter(pane._code, pane._ch);
    if (ch == null) return;
    final verses = pane._plainVerses(ch);
    final buf = StringBuffer('${pane._titleOf(pane._code)} ${pane._ch}\n\n');
    for (final e in verses.entries) {
      buf.writeln('${e.key} ${e.value}');
    }
    buf.write('(${moduleName(pane._moduleId)})');
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
  /// верхней и нижней панелей. Драг ползунка ведётся нотифаером
  /// [_ttsDragN]: перестраивается только плеер, не весь экран
  /// (ADR 0030).
  Widget _ttsPlayer(Palette p) {
    final len = _ttsList.length;
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
          child: ValueListenableBuilder<int?>(
            valueListenable: _ttsDragN,
            builder: (_, drag, _) {
              // Пока ползунок тащат — показываем стих под пальцем.
              final shown = len == 0
                  ? 0
                  : (drag ?? _ttsIndex).clamp(0, len - 1);
              final v = len == 0 ? _ttsVerse : _ttsList[shown].key;
              return Column(
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
                          onPressed: _ttsIndex < len - 1
                              ? () => _seekTts(1)
                              : null,
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
                          // Во время драга — только нотифаер: экран
                          // и текст главы не перестраиваются.
                          onChanged: (x) => _ttsDragN.value = x.round(),
                          onChangeEnd: (x) {
                            final i = x.round();
                            _ttsDragN.value = null;
                            _slideTts(i);
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                ],
              );
            },
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

  /// Тап по стиху: панель действий + на десктопе сразу боковая панель
  /// сносок. Двойной тап по тому же стиху — режим сравнения переводов.
  /// Осталась на экране (B10 этап 1): панель сносок — хром на нотифаере,
  /// меню действий — экранное; в спаны приходит хуком onSelectVerse.
  /// [chCtx] — глава, в которой тапнули (режим «книга»: лента охватывает
  /// всю книгу, и _ch переключается на главу тапнутого стиха).
  void _selectVerse(int v, [int? chCtx]) {
    if (chCtx != null && chCtx != pane._ch) {
      pane._ch = chCtx;
      pane._loadVerseEntries();
    }
    final ch = pane._module?.chapter(pane._code, pane._ch);
    final wide = MediaQuery.of(context).size.width >= 700;
    progress.setVerse(pane._code, pane._ch, v);
    pane._selectedVerse = v;
    pane.rebuild();
    // Панель сносок — свой нотифаер (ADR 0030): открытие не
    // пересобирает текст главы.
    if (wide && ch != null && pane._notesOf(ch).isNotEmpty) {
      _notesOpenN.value = true;
    }
    // Меню действий стиха — у места тапа, в следующем кадре
    // (иначе позиция ещё не проставлена onTapDown).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && pane._selectedVerse == v) _verseMenu(v);
    });
  }

  /// Боковая панель сносок: на десктопе — панель на нотифаере экрана,
  /// на телефоне — шторка. Осталась на экране (B10 этап 1): владелец
  /// панели — хром; записи главы читает у контроллера.
  void _openNotes() {
    final ch = pane._module?.chapter(pane._code, pane._ch);
    if (ch == null) return;
    final notes = pane._notesOf(ch);
    final wide = MediaQuery.of(context).size.width >= 700;
    if (wide) {
      _notesOpenN.value = !_notesOpenN.value;
    } else {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: notes.length > 1 ? 0.6 : 0.3,
          builder: (_, c) => NotesSheet(
            notes: notes,
            selectedVerse: pane._selectedVerse,
            controller: c,
            onRef: pane._goToRef,
            variants: ch.variants,
            openModule: pane._moduleId,
            fromVrs: pane._module?.versification ?? '',
            onOpenModule: pane._goToRefModule,
            panelLoader: pane._panelLoader(pane._ch),
            metaLoader: pane._metaLoader(pane._ch),
          ),
        ),
      );
    }
  }

  /// Всплывающее меню действий стиха — у места тапа (_lastTapPos).
  /// Порядок: выделить, заметка, закладка, теги, сравнить (5-й),
  /// копировать, поделиться.
  Future<void> _verseMenu(int v) async {
    final p = context.palette;

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

    final pos = pane._lastTapPos;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
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
          pane._highlights.containsKey(v)
              ? Icons.highlight
              : Icons.highlight_outlined,
          tr('Выделить', 'Highlight'),
        ),
        mi(
          'note',
          pane._verseNotes.containsKey(v)
              ? Icons.sticky_note_2
              : Icons.edit_outlined,
          tr('Заметка', 'Note'),
        ),
        mi(
          'tags',
          pane._tagEntries.containsKey(v) ? Icons.label : Icons.label_outline,
          tr('Теги', 'Tags'),
        ),
        mi(
          'mark',
          pane._verseMarks.containsKey(v)
              ? Icons.bookmark
              : Icons.bookmark_outline,
          tr('Закладка', 'Bookmark'),
        ),
        // «Сравнить» — стих во всех переводах (экран; список
        // переводов — в настройках).
        mi('cmp', Icons.compare_arrows, tr('Сравнить', 'Compare')),
        // «Параллельные» (карточка стиха, xref-слой) в этой сборке
        // отключены — слой не финализирован (см. dev).
        mi('share', Icons.share_outlined, tr('Поделиться', 'Share')),
      ],
    );
    // Экран мог разобраться за время открытого меню: дальше и диалоги
    // с контекстом, и pane.rebuild() — размонтированному экрану делать
    // нечего (раньше гасился только пункт «Сравнить»).
    if (!mounted) return;
    switch (choice) {
      case 'hl':
        pane._chooseHighlight(context, v);
      case 'note':
        pane._editNote(context, v);
      case 'mark':
        pane._toggleMark(v);
      case 'tags':
        pane._editTags(context, v);
      case 'cmp':
        if (!mounted) return;
        _openScreen('compare', {
          'book': pane._code,
          'ch': pane._ch,
          'v': v,
          'vrs': pane._module?.versification ?? '',
        });
      case 'copy':
        pane._copyVerse(context, v);
      case 'share':
        pane._shareVerse(context, v);
      case null:
        pane._selectedVerse = null; // тап мимо — снять выбор
        pane.rebuild();
    }
  }
}
