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
                            children: _toolActions(p),
                          ),
                        ),
                      ),
                    ),
                  ] else ...[
                    const Spacer(),
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

  /// Нижняя панель управления чтением (только узкий экран):
  /// ‹ › глав + кнопки действий. Полупрозрачное «стекло».
  Widget _controlBar(Palette p, Color color, {required bool wide}) {
    // Фон до нижнего края экрана, содержимое выше системной навигации.
    final bottomInset = MediaQuery.of(context).padding.bottom;
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
              top: BorderSide(color: _ReadingScreenState._glassRim(p)),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            // Стрелок глав нет — главы листаются свайпами; кнопки
            // крупные, равномерно по ширине, у каждой свой цвет.
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: _toolActions(p, search: false, large: true),
            ),
          ),
        ),
      ),
    );
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
