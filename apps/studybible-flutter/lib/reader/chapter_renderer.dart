part of '../screens/reading_screen.dart';

/// Построение текста главы: спаны, вёрстки, подстрочник и сравнение.
extension _ChapterRenderer on _ReadingScreenState {
  // ---------- спаны ----------

  /// Режим «Изучение» (ADR 0015): стих на строку + учебные метки
  /// (сноски, параллельные, подчёркивания Стронга). В режиме
  /// «Чтение» метки скрыты — чистый текст.
  bool get _study => settings.readerMode == ReaderMode.study;

  /// Иврит/арамейский — RTL и специальный шрифт с оглашёнными.
  bool get _isRtl => const {
    'he',
    'hbo',
    'arc',
    'ar',
    'fa',
    'ur',
  }.contains(_module?.language ?? '');

  /// Шрифт тела: для оригиналов — свой (Literata не покрывает
  /// полигонический греческий и иврит с оглашёнными).
  String? _textFont() => switch (_module?.language) {
    'he' || 'hbo' || 'arc' => 'NotoSerifHebrew',
    'grc' || 'el' => 'GentiumBookPlus',
    _ => readingFontFamily(settings.readingFont),
  };

  /// Кегль чтения по умолчанию — 20,5 sp (ADR 0015). Для
  /// вариативной Literata оптический размер следует за кеглем.
  static const double _readingSize = 20.5;

  TextStyle _baseStyle(Palette p) {
    final family = _textFont();
    return TextStyle(
      fontFamily: family,
      fontSize: _readingSize * settings.fontScale,
      color: p.ink,
      height: 1.62,
      fontVariations: family == 'Literata'
          ? [FontVariation('opsz', _readingSize * settings.fontScale)]
          : null,
    );
  }

  /// Цвет номеров стихов — киноварь (ADR 0015): единый акцент чтения,
  /// цвет группы книги остаётся только на плитках сетки.
  Color _verseColor(Palette p) => p.accent;

  TapGestureRecognizer _tap(VoidCallback f) {
    final r = TapGestureRecognizer()..onTap = f;
    _tapRecognizers.add(r);
    return r;
  }

  /// Спаны блока с контекстом стиха: vCtx — стих, к которому относится
  /// текстовый спан (для подсветки читаемого вслух стиха).
  /// [anchorVerses] — стихи, чей номер в этом блоке несёт якорь-ключ
  /// (только первый маркер каждого стиха, иначе дубль GlobalKey).
  List<InlineSpan> _spansOf(
    BlockDoc b,
    Palette p, [
    int? chCtx,
    Set<int>? anchorVerses,
  ]) {
    int? cur;
    var noteIdx = 0;
    final took = <int>{};
    final out = <InlineSpan>[];
    for (final s in b.spans) {
      var anchor = false;
      if (s is VerseSpanDoc) {
        cur = s.verse;
        noteIdx = 0;
        anchor =
            anchorVerses != null &&
            anchorVerses.contains(s.verse) &&
            took.add(s.verse);
      }
      if (s is NoteSpanDoc) {
        out.add(_spanOf(s, p, chCtx, cur, anchor, noteIdx++));
        continue;
      }
      out.add(_spanOf(s, p, chCtx, cur, anchor));
    }
    return out;
  }

  /// Буквы сносок по порядку внутри стиха (без «i», «l», «o» —
  /// их легко спутать с цифрами/буквами слова).
  static const _fnLetters = 'abcdefghjkmnpqrstuvwxyz';

  /// Спаны одного стиха (versePerLine / строчное сравнение):
  /// сноски нумеруются буквами a, b, c… внутри стиха.
  List<InlineSpan> _verseSpans(List<SpanDoc> spans, Palette p, int v) {
    var ni = 0;
    return [
      for (final s in spans)
        if (s is! VerseSpanDoc)
          _spanOf(s, p, null, v, false, s is NoteSpanDoc ? ni++ : 0),
    ];
  }

  InlineSpan _spanOf(
    SpanDoc s,
    Palette p, [
    int? chCtx,
    int? vCtx,
    bool anchor = false,
    int noteIdx = 0,
  ]) {
    final inChapter = chCtx == null || chCtx == _ch;
    if (s is VerseSpanDoc) {
      // Пробелы внутри спана — мишень тапа шире самой цифры.
      // Маркеры: выделение — янтарный фон номера, заметка — точка-маркер,
      // TTS — акцентный фон читаемого стиха.
      // В режиме «книга» маркеры показываются только для текущей главы.
      final hl = inChapter && _highlights.containsKey(s.verse);
      // Якорь стиха: ключ на невидимом виджете на позиции номера —
      // ensureVisible ставит к верху сам стих, а не начало абзаца.
      final vkey = anchor
          ? (chCtx == null
                ? _blockKeys[s.verse]
                : _bookVerseKeys['$chCtx:${s.verse}'])
          : null;
      return TextSpan(
        text:
            '${inChapter && _verseNotes.containsKey(s.verse) ? '\u00B7' : ''}'
            ' ${s.verse} ',
        // Маркеры закладки и тегов — маленькие значки после номера.
        children: [
          if (vkey != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.bottom,
              child: SizedBox.shrink(key: vkey),
            ),
          if (inChapter && _verseMarks.containsKey(s.verse))
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: Icon(Icons.bookmark, size: 11, color: p.accent),
            ),
          if (inChapter && _tagEntries.containsKey(s.verse))
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: Icon(Icons.label, size: 11, color: p.muted),
            ),
        ],
        semanticsLabel: tr('Стих ${s.verse}', 'Verse ${s.verse}'),
        style: TextStyle(
          // Крупнее основного ритма: номер стиха должен читаться
          // как якорь в сплошном абзаце (жалоба: цифры терялись).
          fontSize: 17 * settings.fontScale * 0.86,
          color: _selectedVerse == s.verse ? p.accent : _verseColor(p),
          fontWeight: FontWeight.w800,
          backgroundColor: hl
              ? const Color(0x66FFC34D)
              : (inChapter && _ttsVerse == s.verse
                    ? p.accent.withValues(alpha: 0.30)
                    : null),
        ),
        recognizer: _tap(() => _selectVerse(s.verse, chCtx)),
      );
    }
    if (s is NoteSpanDoc) {
      // В режиме «Чтение» маркеров нет — чистый текст (ADR 0015).
      // В «Изучении» маркеры подчиняются листу «Слои» отдельно:
      // «×» — параллельные места, «*» — сноски.
      if (!_study) return const TextSpan();
      if (s.kind == 'x' ? !settings.layerXrefs : !settings.layerFootnotes) {
        return const TextSpan();
      }
      // Вариант А (ADR 0015): надстрочная буква у слова без пробела;
      // для параллельных мест — «°». Маркер модуля (caller) имеет
      // приоритет над автоматической буквой; '+'/'*' — не буквы.
      final caller = s.caller.trim();
      final mark = s.kind == 'x'
          ? '°'
          : (caller.isNotEmpty && caller != '+' && caller != '*'
                ? caller
                : _fnLetters[noteIdx % _fnLetters.length]);
      // Зона нажатия ~28×28 dp — иначе надстрочный «°»/буква на
      // телефоне почти не нажимается. Отступ снизу имитирует
      // надстрочное положение, кегль чуть больше для читаемости.
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showNoteCard(
            context,
            note: s,
            verse: vCtx ?? 0,
            onRef: _goToRef,
            onShowAll: _openNotes,
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 10),
            child: Semantics(
              label: s.kind == 'x'
                  ? tr('Параллельные места', 'Cross-references')
                  : tr('Сноска $mark', 'Footnote $mark'),
              child: Text(
                mark,
                style: TextStyle(
                  fontSize: 13 * settings.fontScale,
                  fontWeight: FontWeight.w800,
                  color: p.accent,
                  fontFeatures: const [FontFeature.superscripts()],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final t = s as TextSpanDoc;
    final strong = t.strong;
    return TextSpan(
      text: t.text,
      style: TextStyle(
        color: t.style == 'wj' ? p.jesus : p.ink,
        fontStyle: t.style == 'add' ? FontStyle.italic : null,
        decoration: _study && settings.layerStrongs && strong != null
            ? TextDecoration.underline
            : null,
        decorationStyle: TextDecorationStyle.dotted,
        decorationColor: p.muted,
        // Фон читаемого вслух стиха (null!=null-защита: без TTS не красим).
        backgroundColor: inChapter && _ttsVerse != null && vCtx == _ttsVerse
            ? p.accent.withValues(alpha: 0.14)
            : null,
      ),
      recognizer: _study && settings.layerStrongs && strong != null
          ? _tap(() => _showStrong(strong, t.text))
          : null,
    );
  }

  /// Переход по ссылке из сноски («Быт 1:1»): новый экран чтения,
  /// назад — возврат к текущей главе.
  void _goToRef(Ref r) {
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

  void _showStrong(String strong, String word) {
    history.touchDict(strong, word);
    showStrongCard(context, strong, word);
  }

  // ---------- сноски ----------

  /// Сноски главы с привязкой к стиху, где стоит маркер.
  List<({int verse, NoteSpanDoc note})> _notesOf(ChapterDoc ch) {
    final out = <({int verse, NoteSpanDoc note})>[];
    var cur = 0;
    for (final b in ch.blocks) {
      for (final s in b.spans) {
        if (s is VerseSpanDoc) cur = s.verse;
        if (s is NoteSpanDoc) out.add((verse: cur, note: s));
      }
    }
    return out;
  }

  /// Тап по стиху: панель действий + на десктопе сразу боковая панель сносок.
  /// Двойной тап по тому же стиху — режим сравнения переводов.
  /// [chCtx] — глава, в которой тапнули (режим «книга»: лента охватывает
  /// всю книгу, и _ch переключается на главу тапнутого стиха).
  void _selectVerse(int v, [int? chCtx]) {
    if (chCtx != null && chCtx != _ch) {
      _ch = chCtx;
      _loadVerseEntries();
    }
    final ch = _module?.chapter(_code, _ch);
    final wide = MediaQuery.of(context).size.width >= 700;
    final now = DateTime.now();
    final isDouble =
        _lastTapVerse == v &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!).inMilliseconds < 450;
    _lastTapVerse = v;
    _lastTapAt = now;
    progress.setVerse(_code, _ch, v);
    _rebuild(() {
      _selectedVerse = v;
      if (wide && ch != null && _notesOf(ch).isNotEmpty) {
        _notesOpen = true;
      }
      if (isDouble && wide) {
        _compare = true;
      }
    });
  }

  void _openNotes() {
    final ch = _module?.chapter(_code, _ch);
    if (ch == null) return;
    final notes = _notesOf(ch);
    final wide = MediaQuery.of(context).size.width >= 700;
    if (wide) {
      _rebuild(() => _notesOpen = true);
    } else {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: notes.length > 1 ? 0.6 : 0.3,
          builder: (_, c) => NotesSheet(
            notes: notes,
            selectedVerse: _selectedVerse,
            controller: c,
            onRef: _goToRef,
          ),
        ),
      );
    }
  }

  // ---------- выделение текста с привязкой к стихам ----------

  /// Диапазон стихов выделения: номера попавшие в фрагмент
  /// (идут в тексте как « N »); если номеров нет — стих под тапом
  /// или первый главы. `null` — выделения нет.
  ({int lo, int hi})? _selRange() {
    final t = _selectedText;
    if (t == null || t.isEmpty) return null;
    final maxV = _module?.verseCount(_code, _ch) ?? 0;
    final verses = <int>{
      for (final m in RegExp(r' (\d{1,3}) ').allMatches(' $t '))
        int.parse(m.group(1)!),
    }..removeWhere((v) => v < 1 || v > maxV);
    if (verses.isEmpty) {
      final v = (_selectedVerse ?? 1).clamp(1, maxV == 0 ? 1 : maxV);
      return (lo: v, hi: v);
    }
    return (lo: verses.reduce(math.min), hi: verses.reduce(math.max));
  }

  /// Дополнительные пункты контекстного меню выделения.
  List<ContextMenuButtonItem> _selectionMenuItems() {
    final r = _selRange();
    if (r == null) return const [];
    return [
      ContextMenuButtonItem(
        label: tr('Выделить', 'Highlight'),
        onPressed: () => _highlightRange(r.lo, r.hi),
      ),
      ContextMenuButtonItem(
        label: tr('Заметка', 'Note'),
        onPressed: () => _editNote(r.lo),
      ),
    ];
  }

  /// Тулбар выделения — собственный, без адаптивного «…»: на Android
  /// кнопка переполнения AdaptiveTextSelectionToolbar схлопывала всё
  /// меню. Все кнопки — значки; порядок: копировать, выделить цветом,
  /// заметка, затем остальные системные пункты.
  Widget _selectionMenu(BuildContext ctx, SelectableRegionState state) {
    Widget iconBtn(IconData icon, String tip, VoidCallback? f) =>
        TextSelectionToolbarTextButton(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          onPressed: f,
          child: Tooltip(message: tip, child: Icon(icon, size: 18)),
        );
    // Системные custom-пункты (Search, Перевести и т.п.) — тоже иконками,
    // определяя по подписи; совсем неизвестное оставляем текстом.
    Widget stockFallback(ContextMenuButtonItem it) {
      final label = (it.label ?? '').toLowerCase();
      if (label.contains('search') || label.contains('найти')) {
        return iconBtn(Icons.search, it.label ?? '', it.onPressed);
      }
      if (label.contains('translate') || label.contains('перевести')) {
        return iconBtn(Icons.translate, it.label ?? '', it.onPressed);
      }
      return TextSelectionToolbarTextButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        onPressed: it.onPressed,
        child: Text(it.label ?? '', style: const TextStyle(fontSize: 13)),
      );
    }

    Widget iconFor(ContextMenuButtonItem it) => switch (it.type) {
      ContextMenuButtonType.cut => iconBtn(
        Icons.content_cut,
        tr('Вырезать', 'Cut'),
        it.onPressed,
      ),
      ContextMenuButtonType.copy => iconBtn(
        Icons.copy_outlined,
        tr('Копировать', 'Copy'),
        it.onPressed,
      ),
      ContextMenuButtonType.paste => iconBtn(
        Icons.content_paste,
        tr('Вставить', 'Paste'),
        it.onPressed,
      ),
      ContextMenuButtonType.selectAll => iconBtn(
        Icons.select_all,
        tr('Выбрать всё', 'Select all'),
        it.onPressed,
      ),
      ContextMenuButtonType.share => iconBtn(
        Icons.share_outlined,
        tr('Поделиться', 'Share'),
        it.onPressed,
      ),
      ContextMenuButtonType.searchWeb => iconBtn(
        Icons.search,
        tr('Найти', 'Search'),
        it.onPressed,
      ),
      _ => stockFallback(it),
    };
    // Свои действия: сначала закрыть тулбар, само действие — в конце
    // кадра. Иначе OverlayEntry тулбара и route диалога перестраиваются
    // одним проходом и движок редко падает с assert
    // '_dependents.isEmpty' (та же семья, что у _NoteDialog ниже).
    void act(VoidCallback? f) {
      state.hideToolbar();
      if (f == null) return;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) f();
      });
    }

    final ours = _selectionMenuItems();
    final range = _selRange();
    final stock = state.contextMenuButtonItems;
    final copy = stock.where((i) => i.type == ContextMenuButtonType.copy);
    final rest = stock.where((i) => i.type != ContextMenuButtonType.copy);
    return TextSelectionToolbar(
      anchorAbove: state.contextMenuAnchors.primaryAnchor,
      anchorBelow:
          state.contextMenuAnchors.secondaryAnchor ??
          state.contextMenuAnchors.primaryAnchor,
      children: [
        for (final it in copy) iconFor(it),
        if (ours.length > 1 && range != null) ...[
          iconBtn(
            Icons.highlight,
            tr('Выделить цветом', 'Highlight'),
            () => act(ours[0].onPressed),
          ),
          iconBtn(
            Icons.sticky_note_2_outlined,
            tr('Заметка', 'Note'),
            () => act(ours[1].onPressed),
          ),
          iconBtn(
            Icons.bookmark_outline,
            tr('Закладка', 'Bookmark'),
            () => act(() => _toggleMark(range.lo)),
          ),
          iconBtn(
            Icons.label_outline,
            tr('Теги', 'Tags'),
            () => act(() => _editTags(range.lo)),
          ),
        ] else ...[
          for (final it in ours)
            TextSelectionToolbarTextButton(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              onPressed: () => act(it.onPressed),
              child: Text(it.label ?? '', style: const TextStyle(fontSize: 13)),
            ),
        ],
        for (final it in rest) iconFor(it),
      ],
    );
  }

  /// Выделить диапазон стихов (пропускает уже выделенные).
  Future<void> _highlightRange(int lo, int hi) async {
    for (var v = lo; v <= hi; v++) {
      if (_highlights.containsKey(v)) continue;
      final txt = _verseText(v);
      await bridgeEntryAdd(
        kind: 'hl',
        module: _moduleId,
        book: _code,
        chapter: _ch,
        verse: v,
        text: 'yellow',
        context: txt.substring(0, txt.length.clamp(0, 40)),
      );
    }
    await _loadVerseEntries();
  }

  // ---------- построение главы ----------

  /// [peek] — входящая страница листания: якоря и общие ключи не
  /// трогаем (иначе дубль GlobalKey с живой страницей).
  List<Widget> _buildChapter(ChapterDoc ch, Palette p, [bool peek = false]) {
    // Модуль-подстрочник (пары слово/слово в attrs gr="…") во всех
    // режимах рисуется колонками «перевод над оригиналом».
    if (_hasPairs(ch)) return _buildPairsChapter(ch, p, peek: peek);
    // «Изучение» — всегда стих на строку (ADR 0015).
    if (_study || settings.layoutMode == LayoutMode.versePerLine) {
      return _buildVerseLines(ch, p, peek);
    }
    return _buildBlocks(ch, p, peek);
  }

  /// Глава содержит пары подстрочника (спаны w с attrs gr="…").
  bool _hasPairs(ChapterDoc ch) {
    for (final b in ch.blocks) {
      for (final s in b.spans) {
        if (s is TextSpanDoc && s.attrs.contains('gr="')) return true;
      }
    }
    return false;
  }

  /// Лента подстрочника на всю главу: номер стиха + колонки пар.
  /// [chapterNum] — внутри ленты книги: якоря на _bookVerseKeys.
  List<Widget> _buildPairsChapter(
    ChapterDoc ch,
    Palette p, {
    bool peek = false,
    int? chapterNum,
  }) {
    final words = _wordSpans(ch);
    final out = <Widget>[];
    for (final b in ch.blocks) {
      if (b.kind == BlockKind.heading) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(
              _plainText(b),
              style: TextStyle(
                fontFamily: readingFontFamily(settings.readingFont),
                fontSize: 15 * settings.fontScale,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
          ),
        );
        continue;
      }
      if (b.kind == BlockKind.superscription || b.kind == BlockKind.blank) {
        continue;
      }
      for (final s in b.spans) {
        if (s is! VerseSpanDoc) continue;
        final v = s.verse;
        final key = peek
            ? null
            : (chapterNum == null
                  ? _blockKeys.putIfAbsent(v, () => GlobalKey())
                  : _bookVerseKeys.putIfAbsent(
                      '$chapterNum:$v',
                      () => GlobalKey(),
                    ));
        final selected = chapterNum == null && _selectedVerse == v;
        out.add(
          Container(
            key: key,
            color: selected ? p.accent.withValues(alpha: 0.08) : null,
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  button: true,
                  label: tr('Стих $v', 'Verse $v'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => chapterNum == null
                        ? _selectVerse(v)
                        : _selectVerse(v, chapterNum),
                    child: SizedBox(
                      width: 30,
                      child: Text(
                        '$v.',
                        style: TextStyle(
                          fontSize: 13 * settings.fontScale,
                          color: selected ? p.accent : _verseColor(p),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(child: _interlinearLine(words[v] ?? const [], p)),
              ],
            ),
          ),
        );
      }
    }
    return out;
  }

  // ---------- режим «книга»: бесконечная лента всех глав ----------

  /// Лента целой книги: главы идут друг за другом, каждая с жирным
  /// заголовком. Главы подгружаются лениво при прокрутке.
  Widget _bookFeed(Palette p, bool wide) {
    final book = _module?.bookByCode(_code);
    final total = book?.chapters ?? _ch;
    final maxW = settings.columnWidth == ColumnWidth.reading && wide
        ? 720.0
        : double.infinity;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: SelectionArea(
          onSelectionChanged: (c) => _selectedText = c?.plainText,
          contextMenuBuilder: _selectionMenu,
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              wide ? 48 : 20,
              _topClear(),
              wide ? 48 : 20,
              wide ? 16 : _bottomClear(),
            ),
            itemCount: total,
            itemBuilder: (_, i) => _bookChapter(i + 1, p),
          ),
        ),
      ),
    );
  }

  /// Одна глава внутри ленты книги: заголовок «Глава N» + её блоки.
  /// Загружается через ensureChapter — до загрузки короткий спейсер.
  Widget _bookChapter(int n, Palette p) {
    final m = _module;
    final ch = m?.chapter(_code, n);
    if (ch == null) {
      if (m != null) _ensureChapter(m, _code, n);
      return const SizedBox(height: 60);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(top: n == 1 ? 4 : 28, bottom: 12),
          child: Text(
            tr('Глава $n', 'Chapter $n'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: readingFontFamily(settings.readingFont),
              fontSize: 19 * settings.fontScale,
              fontWeight: FontWeight.w800,
              color: _verseColor(p),
            ),
          ),
        ),
        // Подстрочник — колонками пар «перевод над оригиналом».
        ..._hasPairs(ch)
            ? _buildPairsChapter(ch, p, chapterNum: n)
            : _bookBlocks(ch, p, n),
      ],
    );
  }

  /// Блоки главы для ленты: те же абзацы/поэзия/заголовки, но без
  /// _blockKeys (прокрутка к стиху здесь не используется) и с тапом,
  /// переключающим _ch на главу тапнутого стиха.
  List<Widget> _bookBlocks(
    ChapterDoc ch,
    Palette p,
    int chapterNum, [
    bool peek = false,
  ]) {
    // Первый проход: стих -> блок, где он начинается — для прокрутки
    // к стиху по ссылке (ключи «глава:стих», номера повторяются).
    final verseBlock = <int, int>{};
    for (var i = 0; i < ch.blocks.length; i++) {
      for (final s in ch.blocks[i].spans) {
        if (s is VerseSpanDoc) {
          verseBlock.putIfAbsent(s.verse, () => i);
          if (!peek) {
            _bookVerseKeys.putIfAbsent(
              '$chapterNum:${s.verse}',
              () => GlobalKey(),
            );
          }
        }
      }
    }
    final out = <Widget>[];
    for (var i = 0; i < ch.blocks.length; i++) {
      final b = ch.blocks[i];
      // Стихи, чей первый маркер в этом блоке, — несут якорь-ключ
      // на самом номере (точная прокрутка к стиху внутри абзаца).
      final anchorVerses = peek
          ? const <int>{}
          : verseBlock.entries
                .where((e) => e.value == i)
                .map((e) => e.key)
                .toSet();
      switch (b.kind) {
        case BlockKind.heading:
          out.add(
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 8),
              child: Text(
                _plainText(b),
                style: TextStyle(
                  fontFamily: readingFontFamily(settings.readingFont),
                  fontSize: 15 * settings.fontScale,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
            ),
          );
        case BlockKind.superscription:
          out.add(
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _plainText(b),
                  style: TextStyle(
                    fontFamily: readingFontFamily(settings.readingFont),
                    fontSize: 13 * settings.fontScale,
                    fontStyle: FontStyle.italic,
                    color: p.muted,
                  ),
                ),
              ),
            ),
          );
        case BlockKind.blank:
          out.add(const SizedBox(height: 8));
        case BlockKind.poetry:
          out.add(
            Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 6),
              child: Text.rich(
                TextSpan(
                  style: _baseStyle(p),
                  children: _spansOf(b, p, chapterNum, anchorVerses),
                ),
              ),
            ),
          );
        case BlockKind.paragraph:
          out.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text.rich(
                TextSpan(
                  style: _baseStyle(p),
                  children: [
                    const TextSpan(text: '\u2003'),
                    ..._spansOf(b, p, chapterNum, anchorVerses),
                  ],
                ),
              ),
            ),
          );
      }
    }
    return out;
  }

  List<Widget> _buildBlocks(ChapterDoc ch, Palette p, [bool peek = false]) {
    // Первый проход: стих -> блок, где он начинается (для прокрутки).
    final verseBlock = <int, int>{};
    for (var i = 0; i < ch.blocks.length; i++) {
      for (final s in ch.blocks[i].spans) {
        if (s is VerseSpanDoc) {
          verseBlock.putIfAbsent(s.verse, () => i);
          if (!peek) _blockKeys.putIfAbsent(s.verse, () => GlobalKey());
        }
      }
    }
    final out = <Widget>[];
    for (var i = 0; i < ch.blocks.length; i++) {
      final b = ch.blocks[i];
      // Стихи, чей первый маркер в этом блоке, — несут якорь-ключ
      // на самом номере (точная прокрутка к стиху внутри абзаца).
      final anchorVerses = peek
          ? const <int>{}
          : verseBlock.entries
                .where((e) => e.value == i)
                .map((e) => e.key)
                .toSet();
      switch (b.kind) {
        case BlockKind.heading:
          out.add(
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 8),
              child: Text(
                _plainText(b),
                style: TextStyle(
                  fontFamily: readingFontFamily(settings.readingFont),
                  fontSize: 15 * settings.fontScale,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
            ),
          );
        case BlockKind.superscription:
          out.add(
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _plainText(b),
                  style: TextStyle(
                    fontFamily: readingFontFamily(settings.readingFont),
                    fontSize: 13 * settings.fontScale,
                    fontStyle: FontStyle.italic,
                    color: p.muted,
                  ),
                ),
              ),
            ),
          );
        case BlockKind.blank:
          out.add(const SizedBox(height: 8));
        case BlockKind.poetry:
          out.add(
            Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 6),
              child: Text.rich(
                TextSpan(
                  style: _baseStyle(p),
                  children: _spansOf(b, p, null, anchorVerses),
                ),
              ),
            ),
          );
        case BlockKind.paragraph:
          out.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text.rich(
                TextSpan(
                  style: _baseStyle(p),
                  // Красная строка — как в печатных изданиях.
                  children: [
                    const TextSpan(text: '\u2003'),
                    ..._spansOf(b, p, null, anchorVerses),
                  ],
                ),
              ),
            ),
          );
      }
    }
    return out;
  }

  /// versePerLine: каждый стих — отдельная строка.
  List<Widget> _buildVerseLines(ChapterDoc ch, Palette p, [bool peek = false]) {
    final out = <Widget>[];
    final verses = <int, List<SpanDoc>>{};
    final order = <int>[];
    var cur = -1;
    for (final b in ch.blocks) {
      if (b.kind == BlockKind.heading) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(
              _plainText(b),
              style: TextStyle(
                fontFamily: readingFontFamily(settings.readingFont),
                fontSize: 15 * settings.fontScale,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
          ),
        );
        continue;
      }
      if (b.kind == BlockKind.superscription) {
        out.add(
          Center(
            child: Text(
              _plainText(b),
              style: TextStyle(
                fontFamily: readingFontFamily(settings.readingFont),
                fontSize: 13 * settings.fontScale,
                fontStyle: FontStyle.italic,
                color: p.muted,
              ),
            ),
          ),
        );
        continue;
      }
      for (final s in b.spans) {
        if (s is VerseSpanDoc) {
          cur = s.verse;
          verses.putIfAbsent(cur, () => []);
          order.add(cur);
        } else if (cur >= 0) {
          verses[cur]!.add(s);
        }
      }
    }
    for (final v in order) {
      if (!peek) _blockKeys.putIfAbsent(v, () => GlobalKey());
      final selected = _selectedVerse == v;
      final hl = _highlights.containsKey(v);
      out.add(
        Container(
          key: peek ? null : _blockKeys[v],
          color: selected
              ? p.accent.withValues(alpha: 0.08)
              : (hl ? const Color(0x33FFC34D) : null),
          // Строки чуть реже абзацев: номер слева должен «дышать».
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                button: true,
                label: tr('Стих $v', 'Verse $v'),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _selectVerse(v),
                  child: SizedBox(
                    width: 40,
                    // Номер стиха — крупная «вешалка» слева, как в
                    // классических читалках (образец );
                    // под номером — мини-маркеры закладки и тегов.
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$v',
                          style: TextStyle(
                            fontSize: 17 * settings.fontScale * 0.95,
                            color: selected ? p.accent : _verseColor(p),
                            fontWeight: FontWeight.w800,
                            height: 1.4,
                          ),
                        ),
                        if (_verseMarks.containsKey(v) ||
                            _tagEntries.containsKey(v))
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_verseMarks.containsKey(v))
                                Icon(Icons.bookmark, size: 10, color: p.accent),
                              if (_tagEntries.containsKey(v))
                                Icon(Icons.label, size: 10, color: p.muted),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: _baseStyle(p),
                    children: _verseSpans(verses[v]!, p, v),
                  ),
                ),
              ),
              if (_verseNotes.containsKey(v))
                Semantics(
                  button: true,
                  label: tr('Заметка к стиху $v', 'Note for verse $v'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _selectVerse(v),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4, top: 2),
                      child: Icon(
                        Icons.sticky_note_2_outlined,
                        size: 15,
                        color: p.accent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return out;
  }

  /// Стих -> плоский текст главы (без номеров и сносок) —
  /// для второго перевода в строчном сравнении.
  Map<int, String> _plainVerses(ChapterDoc ch) {
    final out = <int, StringBuffer>{};
    var cur = -1;
    for (final b in ch.blocks) {
      if (b.kind == BlockKind.heading ||
          b.kind == BlockKind.superscription ||
          b.kind == BlockKind.blank) {
        continue;
      }
      for (final s in b.spans) {
        if (s is VerseSpanDoc) {
          cur = s.verse;
        } else if (cur >= 0 && s is TextSpanDoc) {
          out.putIfAbsent(cur, StringBuffer.new).write(s.text);
        }
      }
    }
    return {for (final e in out.entries) e.key: e.value.toString().trim()};
  }

  /// Слова оригинала по стихам — спаны style='w' (strong/lemma в attrs).
  Map<int, List<TextSpanDoc>> _wordSpans(ChapterDoc ch) {
    final out = <int, List<TextSpanDoc>>{};
    var cur = -1;
    for (final b in ch.blocks) {
      if (b.kind == BlockKind.heading ||
          b.kind == BlockKind.superscription ||
          b.kind == BlockKind.blank) {
        continue;
      }
      for (final s in b.spans) {
        if (s is VerseSpanDoc) {
          cur = s.verse;
        } else if (cur >= 0 && s is TextSpanDoc && s.style == 'w') {
          out.putIfAbsent(cur, () => []).add(s);
        }
      }
    }
    return out;
  }

  /// Лента подстрочника: каждое слово — колонка «слово оригинала /
  /// краткая глосса». Для иврита — RTL.
  Widget _interlinearLine(List<TextSpanDoc> words, Palette p) {
    final lang = _mods[_compareModuleId]?.language ?? '';
    final rtl = lang == 'he' || lang == 'hbo' || lang == 'arc';
    final font = switch (lang) {
      'he' || 'hbo' || 'arc' => 'NotoSerifHebrew',
      'grc' || 'el' => 'GentiumBookPlus',
      _ => readingFontFamily(settings.readingFont),
    };
    final wrap = Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        for (final w in words)
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                w.text.trim().replaceAll('/', ''),
                style: TextStyle(
                  fontFamily: font,
                  fontSize: 15 * settings.fontScale,
                  fontWeight: w.attrs.contains('gr=') ? FontWeight.w600 : null,
                  color: p.ink,
                  height: 1.3,
                ),
              ),
              Text(
                _glossOf(w),
                style: TextStyle(
                  fontFamily: w.attrs.contains('gr=')
                      ? 'GentiumBookPlus'
                      : null,
                  fontSize:
                      (w.attrs.contains('gr=') ? 12 : 10) * settings.fontScale,
                  color: p.muted,
                  height: 1.2,
                ),
              ),
            ],
          ),
      ],
    );
    return Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: wrap,
    );
  }

  /// Краткая глосса слова: слово оригинала из пары подстрочника
  /// (attrs gr="…"), иначе определение из словаря Стронга, иначе
  /// сам номер Стронга, иначе морфология.
  String _glossOf(TextSpanDoc w) {
    final g = RegExp(r'gr="([^"]*)"').firstMatch(w.attrs);
    if (g != null) return g.group(1) ?? '';
    final s = w.strong;
    if (s != null) {
      final e = _lex?[s];
      if (e != null && e.expl.isNotEmpty) {
        final cut = e.expl.indexOf(';');
        return cut > 0 ? e.expl.substring(0, cut) : e.expl;
      }
      return s;
    }
    final m = RegExp(r'lemma="([^"]+)"').firstMatch(w.attrs);
    return m?.group(1) ?? '';
  }

  void _ensureLex() {
    if (_lex != null) return;
    lexicon().then((d) {
      if (mounted) _rebuild(() => _lex = d);
    });
  }

  /// Строчное сравнение: стих основного перевода, под ним — тот же
  /// стих второго перевода (приглушённый). Если во втором модуле
  /// есть слова с номерами Стронга (оригиналы OSHB/UGNT), вторая
  /// строка рисуется как подстрочник: слово оригинала + глосса.
  List<Widget> _buildInterleaved(ChapterDoc ch, Palette p) {
    final second = _mods[_compareModuleId]?.chapter(_code, _ch);
    if (second == null) {
      final m = _mods[_compareModuleId];
      if (m != null) _ensureChapter(m, _code, _ch);
    }
    final secondVerses = second == null
        ? const <int, String>{}
        : _plainVerses(second);
    final secondWords = second == null
        ? const <int, List<TextSpanDoc>>{}
        : _wordSpans(second);
    final interlinear = secondWords.isNotEmpty;
    if (interlinear) _ensureLex();
    final out = <Widget>[];
    final verses = <int, List<SpanDoc>>{};
    final order = <int>[];
    var cur = -1;
    for (final b in ch.blocks) {
      if (b.kind == BlockKind.heading) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(
              _plainText(b),
              style: TextStyle(
                fontFamily: readingFontFamily(settings.readingFont),
                fontSize: 15 * settings.fontScale,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
          ),
        );
        continue;
      }
      if (b.kind == BlockKind.superscription) {
        out.add(
          Center(
            child: Text(
              _plainText(b),
              style: TextStyle(
                fontFamily: readingFontFamily(settings.readingFont),
                fontSize: 13 * settings.fontScale,
                fontStyle: FontStyle.italic,
                color: p.muted,
              ),
            ),
          ),
        );
        continue;
      }
      for (final s in b.spans) {
        if (s is VerseSpanDoc) {
          cur = s.verse;
          verses.putIfAbsent(cur, () => []);
          order.add(cur);
        } else if (cur >= 0) {
          verses[cur]!.add(s);
        }
      }
    }
    for (final v in order) {
      _blockKeys.putIfAbsent(v, () => GlobalKey());
      final selected = _selectedVerse == v;
      final hl = _highlights.containsKey(v);
      out.add(
        Container(
          key: _blockKeys[v],
          color: selected
              ? p.accent.withValues(alpha: 0.08)
              : (hl ? const Color(0x33FFC34D) : null),
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    button: true,
                    label: tr('Стих $v', 'Verse $v'),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _selectVerse(v),
                      child: SizedBox(
                        width: 30,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '$v.',
                              style: TextStyle(
                                fontSize: 13 * settings.fontScale,
                                color: selected ? p.accent : _verseColor(p),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_verseMarks.containsKey(v) ||
                                _tagEntries.containsKey(v))
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_verseMarks.containsKey(v))
                                    Icon(
                                      Icons.bookmark,
                                      size: 9,
                                      color: p.accent,
                                    ),
                                  if (_tagEntries.containsKey(v))
                                    Icon(Icons.label, size: 9, color: p.muted),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: _baseStyle(p),
                        children: _verseSpans(verses[v]!, p, v),
                      ),
                    ),
                  ),
                ],
              ),
              // Второй перевод: та же строчка, приглушённая;
              // у модулей оригинала — подстрочник слово-к-слову.
              if (interlinear)
                Padding(
                  padding: const EdgeInsets.only(left: 30, top: 2, bottom: 4),
                  child: _interlinearLine(secondWords[v] ?? const [], p),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(left: 30, top: 2, bottom: 4),
                  child: Text(
                    secondVerses[v] ?? '…',
                    style: TextStyle(
                      fontFamily: readingFontFamily(settings.readingFont),
                      fontSize: 15 * settings.fontScale,
                      color: p.muted,
                      fontStyle: FontStyle.italic,
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return out;
  }

  String _plainText(BlockDoc b) => [
    for (final s in b.spans)
      if (s is TextSpanDoc) s.text,
  ].join();

  // ---------- экран ----------

  /// Кнопки панели управления чтением (перевод, сравнение, TTS…).
  /// [large] — мобильная нижняя панель: иконки крупнее и каждая со
  /// своим цветом-акцентом; активное состояние всегда accent.
}
