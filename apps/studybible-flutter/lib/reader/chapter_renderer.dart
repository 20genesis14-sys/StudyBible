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
    // Ступень насыщенности (настройка): для вариативной Literata —
    // точный wght, для статических шрифтов — FontWeight.
    final wght = Settings.kFontWeightSteps[settings.fontWeightStep].toDouble();
    // Ось wght есть у всех переменных шрифтов набора; у Literata ещё и
    // оптический размер opsz, следующий за кеглем.
    final variations = <FontVariation>[
      if (family == 'Literata')
        FontVariation('opsz', _readingSize * settings.fontScale),
      if (const {
        'Literata',
        'Lora',
        'Alegreya',
        'SourceSerif4',
        'RobotoSerif',
        'PaperMono',
      }.contains(family))
        FontVariation('wght', wght),
    ];
    return TextStyle(
      fontFamily: family,
      fontSize: _readingSize * settings.fontScale,
      fontWeight: settings.readingWeight,
      color: p.ink,
      height: 1.62,
      fontVariations: variations.isEmpty ? null : variations,
    );
  }

  /// Цвет номеров стихов — киноварь (ADR 0015): единый акцент чтения,
  /// цвет группы книги остаётся только на плитках сетки.
  Color _verseColor(Palette p) => p.accent;

  TapGestureRecognizer _tap(VoidCallback f) {
    final r = TapGestureRecognizer()
      ..onTap = f
      ..onTapDown = (d) => _lastTapPos = d.globalPosition;
    _tapRecognizers.add(r);
    return r;
  }

  /// Долгое нажатие — карточка Стронга из выделенного слова
  /// (тап на выделенном куске занят меню фрагмента).
  LongPressGestureRecognizer _longPress(VoidCallback f) {
    final r = LongPressGestureRecognizer()..onLongPress = f;
    _tapRecognizers.add(r);
    return r;
  }

  /// Спаны блока с контекстом стиха: vCtx — стих, к которому относится
  /// текстовый спан (для подсветки читаемого вслух стиха).
  /// [anchorVerses] — стихи, чей номер в этом блоке несёт якорь-ключ
  /// (только первый маркер каждого стиха, иначе дубль GlobalKey).
  /// [hideVerse] — номер стиха, чей маркер не рисуется (буквица
  /// главы совмещает роль якоря стиха 1: дубли «1 1Текст» в печатных
  /// изданиях не ставят). Спан всё равно обрабатывается — якорный
  /// ключ, иконки закладки/тегов, точка заметки и курсоры TTS/
  /// выделений сохраняются, пропадает только сама цифра.
  List<InlineSpan> _spansOf(
    BlockDoc b,
    Palette p, [
    int? chCtx,
    Set<int>? anchorVerses,
    int? hideVerse,
  ]) {
    int? cur;
    var noteIdx = 0;
    final took = <int>{};
    final out = <InlineSpan>[];
    // _spansOf строит только основной текст главы — словесная
    // подсветка здесь разрешена (сравнение идёт через _verseSpans
    // с hlWord=false и контекст выключает).
    _ttsWordCtx = true;
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
      out.add(
        _spanOf(
          s,
          p,
          chCtx,
          cur,
          anchor,
          0,
          s is VerseSpanDoc && s.verse == hideVerse,
        ),
      );
    }
    return out;
  }

  /// Буквы сносок по порядку внутри стиха (без «i», «l», «o» —
  /// их легко спутать с цифрами/буквами слова).
  static const _fnLetters = 'abcdefghjkmnpqrstuvwxyz';

  /// Пословная подсветка читаемого стиха (ADR 0017): слово движка
  /// приходит в смещениях «плоского» текста стиха (трим по краям);
  /// при построении спанов считаем сырой сдвиг по конкатенации
  /// текстов стиха и ведущие пробелы, чтобы красить точные символы.
  /// Поля курсора живут в _ReadingScreenState (в extension им
  /// не место): _ttsInVerse/_ttsRaw/_ttsLead/_ttsLeadDone.

  /// Текущее слово — только если включена настройка подсветки слов.
  WordMark? get _ttsWord => settings.voiceWords ? _ttsService.word : null;

  /// Спаны одного стиха (versePerLine / строчное сравнение):
  /// сноски нумеруются буквами a, b, c… внутри стиха.
  /// [hlWord] — этот стих принадлежит основному тексту главы
  /// (для колонки сравнения — false: чужие смещения слов к чужому
  /// тексту неприменимы).
  List<InlineSpan> _verseSpans(
    List<SpanDoc> spans,
    Palette p,
    int v, {
    bool hlWord = false,
  }) {
    var ni = 0;
    _hlRaw = 0; // спаны стиха строятся с начала — курсор кусков с нуля
    _ttsWordCtx = hlWord && v == _ttsVerse && _ttsWord != null;
    if (_ttsWordCtx) {
      _ttsInVerse = true;
      _ttsRaw = 0;
      _ttsLead = 0;
      _ttsLeadDone = false;
    }
    return [
      for (final s in spans)
        if (s is! VerseSpanDoc)
          _spanOf(s, p, null, v, false, s is NoteSpanDoc ? ni++ : 0),
    ];
  }

  /// [suppressVerse] — маркер стиха без цифры: якорь и иконки меток
  /// остаются, номер скрыт за буквицей главы.
  InlineSpan _spanOf(
    SpanDoc s,
    Palette p, [
    int? chCtx,
    int? vCtx,
    bool anchor = false,
    int noteIdx = 0,
    bool suppressVerse = false,
  ]) {
    final inChapter = chCtx == null || chCtx == _ch;
    if (s is VerseSpanDoc) {
      // Курсор пословной подсветки: внутри читаемого стиха считаем
      // сырой сдвиг текстовых спанов (стих может тянуться через
      // несколько блоков — счётчик не сбрасывается по границе блока).
      _ttsInVerse = inChapter && _ttsVerse == s.verse;
      if (_ttsInVerse) {
        _ttsRaw = 0;
        _ttsLead = 0;
        _ttsLeadDone = false;
      }
      // Пробелы внутри спана — мишень тапа шире самой цифры.
      // Маркеры: выделение — янтарный фон номера, заметка — точка-маркер,
      // TTS — акцентный фон читаемого стиха.
      // В режиме «книга» маркеры показываются только для текущей главы.
      final hlEntry = inChapter ? _wholeHl(s.verse) : null;
      _hlRaw = 0; // новый стих — новый курсор частичных выделений
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
            '${suppressVerse ? '' : ' ${s.verse} '}',
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
          fontSize: 19 * settings.fontScale,
          color: _selectedVerse == s.verse ? p.accent : _verseColor(p),
          fontWeight: FontWeight.w800,
          backgroundColor: hlEntry != null
              ? highlightColor(hlEntry.text).withValues(alpha: 0.45)
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
            openModule: _moduleId,
            onRef: _goToRef,
            fromVrs: _module?.versification ?? '',
            onOpenModule: _goToRefModule,
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
    final style = TextStyle(
      color: t.style == 'wj' ? p.jesus : p.ink,
      fontStyle: t.style == 'add' ? FontStyle.italic : null,
      decoration: _study && settings.layerStrongs && strong != null
          ? TextDecoration.underline
          : null,
      decorationStyle: TextDecorationStyle.dotted,
      decorationColor: p.muted,
      // Фон стиха: целостишовое выделение — цвет записи; иначе фон
      // читаемого вслух стиха (null!=null-защита: без TTS не красим).
      backgroundColor: vCtx != null && inChapter && _wholeHl(vCtx) != null
          ? highlightColor(_wholeHl(vCtx)!.text).withValues(alpha: 0.2)
          : (inChapter && _ttsVerse != null && vCtx == _ttsVerse
                ? p.accent.withValues(alpha: 0.14)
                : null),
    );
    // Стронг — по долгому нажатию: тап у выделенных кусков занят
    // меню фрагмента (решение пользователя, 14.10.2026).
    final recognizer = _study && settings.layerStrongs && strong != null
        ? _longPress(() => _showStrong(strong, t.text))
        : null;
    // Сырой сдвиг по текстовым спанам стиха — под него размечены
    // диапазоны частичных выделений (_hlFrags, frag-селекторы).
    final raw0 = _hlRaw;
    _hlRaw += t.text.length;
    final cuts = <({int s, int e, Color c, UserEntry? rec})>[
      if (vCtx != null && inChapter)
        for (final r
            in _hlFrags[vCtx] ?? const <({UserEntry rec, int s, int e})>[])
          if ((r.e - raw0).clamp(0, t.text.length) >
              (r.s - raw0).clamp(0, t.text.length))
            (
              s: (r.s - raw0).clamp(0, t.text.length),
              e: (r.e - raw0).clamp(0, t.text.length),
              c: highlightColor(r.rec.text).withValues(alpha: 0.45),
              rec: r.rec,
            ),
    ];
    // Пословная подсветка: смещения движка — в «плоском» тексте стиха
    // (без краевых пробелов); переводим в сырой сдвиг по спанам и
    // красим участок сильнее фона стиха.
    if (_ttsWordCtx &&
        _ttsInVerse &&
        inChapter &&
        vCtx == _ttsVerse &&
        t.text.isNotEmpty) {
      if (!_ttsLeadDone) {
        final lead = t.text.length - t.text.trimLeft().length;
        _ttsLead += lead;
        if (lead < t.text.length) _ttsLeadDone = true;
      }
      final raw = _ttsRaw;
      _ttsRaw += t.text.length;
      final w = _ttsWord;
      if (w != null) {
        final ws = (w.start + _ttsLead - raw).clamp(0, t.text.length);
        final we = (w.end + _ttsLead - raw).clamp(0, t.text.length);
        if (we > ws) {
          cuts.add((
            s: ws,
            e: we,
            c: p.accent.withValues(alpha: 0.45),
            rec: null,
          ));
        }
      }
    } else if (_ttsInVerse && _ttsWordCtx) {
      // Счётчик идёт по спанам читаемого стиха и без подсветки —
      // иначе позиция слова собьётся у следующих спанов.
      _ttsRaw += t.text.length;
    }
    if (cuts.isEmpty) {
      return TextSpan(text: t.text, style: style, recognizer: recognizer);
    }
    // Границы всех диапазонов режут спан на куски; при наложении
    // выигрывает диапазон, добавленный позже (TTS-слово — над
    // цветным выделением).
    final pts = <int>{0, t.text.length};
    for (final c in cuts) {
      pts
        ..add(c.s)
        ..add(c.e);
    }
    final ordered = pts.toList()..sort();
    return TextSpan(
      style: style,
      recognizer: recognizer,
      children: [
        for (var i = 0; i + 1 < ordered.length; i++)
          TextSpan(
            text: t.text.substring(ordered[i], ordered[i + 1]),
            style: TextStyle(
              backgroundColor: cuts
                  .where((c) => c.s <= ordered[i] && c.e >= ordered[i + 1])
                  .lastOrNull
                  ?.c,
            ),
            // Тап по подсвеченному куску — его меню (цвет/заметка/
            // снятие именно этой записи, схема 4).
            recognizer:
                cuts
                        .where(
                          (c) => c.s <= ordered[i] && c.e >= ordered[i + 1],
                        )
                        .lastOrNull
                        ?.rec ==
                    null
                ? null
                : _tap(
                    () => _fragMenu(
                      cuts
                          .where(
                            (c) => c.s <= ordered[i] && c.e >= ordered[i + 1],
                          )
                          .last
                          .rec!,
                    ),
                  ),
          ),
      ],
    );
  }

  /// Переход по ссылке из сноски («Быт 1:1»): переход в стеке
  /// рабочего места, «назад» возвращает к текущей позиции (ADR 0019).
  void _goToRef(Ref r) => _navTo(r, _moduleId);

  /// Переход к конвертированному месту в другом переводе (тап по
  /// тексту параллельного места из xrefModule — координата уже в
  /// версификации этого перевода).
  void _goToRefModule(Ref r, String moduleId) => _navTo(r, moduleId);

  void _navTo(Ref r, String moduleId) {
    final loc = Location.verse(
      moduleId: moduleId,
      book: r.book,
      chapter: r.chapter,
      verse: r.verse,
      pane: _paneSnapshot(),
    );
    workspace.go(loc);
    _applyLocation(loc);
  }

  void _showStrong(String strong, String word) {
    history.touchDict(strong, word);
    showStrongCard(context, strong, word);
  }

  // ---------- сноски ----------

  /// Сноски главы с привязкой к стиху, где стоит маркер.
  List<({int verse, NoteSpanDoc note})> _notesOf(ChapterDoc ch) {
    final cached = ch.notesCache;
    if (cached != null) return cached;
    final out = <({int verse, NoteSpanDoc note})>[];
    var cur = 0;
    for (final b in ch.blocks) {
      for (final s in b.spans) {
        if (s is VerseSpanDoc) cur = s.verse;
        if (s is NoteSpanDoc) out.add((verse: cur, note: s));
      }
    }
    ch.notesCache = out;
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
    progress.setVerse(_code, _ch, v);
    _rebuild(() {
      _selectedVerse = v;
      if (wide && ch != null && _notesOf(ch).isNotEmpty) {
        _notesOpen = true;
      }
    });
    // Меню действий стиха — у места тапа, в следующем кадре
    // (иначе позиция ещё не проставлена onTapDown).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedVerse == v) _verseMenu(v);
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
            variants: ch.variants,
          ),
        ),
      );
    }
  }

  // ---------- выделение текста с привязкой к стихам ----------

  /// Стих, чей маркер ближе всего к точке pointer-down — в порядке
  /// чтения (выше строки или в той же строке левее). Маркер стиха —
  /// невидимый виджет на позиции номера (ключи _blockKeys).
  int? _verseAtPoint(Offset p) {
    int? best;
    Offset? bestPos;
    for (final e in _blockKeys.entries) {
      final ro = e.value.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached) continue;
      final o = ro.localToGlobal(Offset.zero);
      final before =
          o.dy < p.dy - 6 || ((o.dy - p.dy).abs() <= 6 && o.dx <= p.dx + 2);
      if (!before) continue;
      if (best == null ||
          o.dy > bestPos!.dy + 6 ||
          ((o.dy - bestPos.dy).abs() <= 6 && o.dx > bestPos.dx)) {
        best = e.key;
        bestPos = o;
      }
    }
    return best;
  }

  /// Стих, содержащий выделенный текст: запасная привязка, когда
  /// в выделении нет маркеров номеров и нет позиции указателя.
  /// Неоднозначно для повторяющихся слов — поэтому только fallback.
  int? _verseContaining(String t) {
    final q = t.trim();
    if (q.isEmpty) return null;
    final maxV = _module?.verseCount(_code, _ch) ?? 0;
    final sel = _selectedVerse;
    if (sel != null && sel >= 1 && sel <= maxV && _verseText(sel).contains(q)) {
      return sel;
    }
    for (var v = 1; v <= maxV; v++) {
      if (_verseText(v).contains(q)) return v;
    }
    return null;
  }

  /// Диапазон стихов выделения: номера попавшие в фрагмент
  /// (идут в тексте как « N »); если номеров нет — стих находим
  /// по содержимому ([_verseContaining]), иначе под тапом.
  /// `null` — выделения нет или привязать не удалось.
  ({int lo, int hi})? _selRange(String? t) {
    if (t == null || t.isEmpty) return null;
    final maxV = _module?.verseCount(_code, _ch) ?? 0;
    final padded = ' $t ';
    final matches = RegExp(r' (\d{1,3}) ').allMatches(padded).toList();
    final verses = <int>{
      for (final m in matches) int.parse(m.group(1)!),
      // Головной кусок до первого маркера — хвост стиха на
      // единицу меньше первого номера.
      if (matches.isNotEmpty &&
          padded.substring(0, matches.first.start).trim().isNotEmpty)
        int.parse(matches.first.group(1)!) - 1,
    }..removeWhere((v) => v < 1 || v > maxV);
    if (verses.isEmpty) {
      final v =
          _selAnchorVerse ??
          _verseContaining(t) ??
          (_selectedVerse ?? 1).clamp(1, maxV == 0 ? 1 : maxV);
      return (lo: v, hi: v);
    }
    return (lo: verses.reduce(math.min), hi: verses.reduce(math.max));
  }

  /// Куски выделения по стихам: выделенный текст режется по
  /// маркерам « N »; головной кусок (до первого маркера) — хвост
  /// стиха lo. verse -> выделенная часть текста этого стиха.
  Map<int, String> _selChunks(String? t) {
    final r = _selRange(t);
    if (t == null || r == null) return const {};
    final padded = ' $t ';
    final matches = RegExp(r' (\d{1,3}) ').allMatches(padded).toList();
    if (matches.isEmpty) {
      final v = _selAnchorVerse ?? _verseContaining(t) ?? r.lo;
      return {v: t};
    }
    final out = <int, String>{};
    final firstNum = int.parse(matches.first.group(1)!);
    // Головной кусок до первого маркера — хвост стиха
    // firstNum-1 (выделение началось в середине стиха).
    if (padded.substring(0, matches.first.start).trim().isNotEmpty &&
        firstNum > 1) {
      out[firstNum - 1] = padded.substring(0, matches.first.start);
    }
    for (var i = 0; i < matches.length; i++) {
      final num = int.parse(matches[i].group(1)!);
      final to = i + 1 < matches.length ? matches[i + 1].start : padded.length;
      out[num] = padded.substring(matches[i].end, to);
    }
    return out;
  }

  /// Дополнительные пункты контекстного меню выделения.
  List<ContextMenuButtonItem> _selectionMenuItems() {
    // Текст выделения фиксируем при показе меню: после hideToolbar/
    // диалога палитры selection снимается и _selectedText = null.
    final t = _selectedText;
    final r = _selRange(t);
    if (r == null) return const [];
    return [
      ContextMenuButtonItem(
        label: tr('Выделить', 'Highlight'),
        onPressed: () => _pickHighlightColor().then((c) {
          if (c != null && c != 'remove') _highlightRange(t, c);
        }),
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
    final range = _selRange(_selectedText);
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

  /// Выбор цвета выделения — «пилюля» с кружками цветов; [current]
  /// отмечается галочкой, [removable] — корзина «Убрать», [note] —
  /// кнопка заметки к фразе ([hasNote] — уже есть, иконка полная).
  /// Возвращает имя цвета, 'remove', 'note' или null (отмена).
  Future<String?> _pickHighlightColor({
    String? current,
    bool removable = false,
    bool note = false,
    bool hasNote = false,
  }) {
    final p = context.palette;
    // Без затемнения экрана: пилюля поверх текста, тап мимо
    // закрывает (решение пользователя, 14.10.2026).
    return showDialog<String>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => Dialog(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in kHighlightColors.entries)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(ctx).pop(e.key),
                  child: Container(
                    width: 26,
                    height: 26,
                    margin: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: e.value,
                      shape: BoxShape.circle,
                      border: Border.all(color: p.edge),
                    ),
                    child: e.key == current
                        ? const Icon(Icons.check, size: 15)
                        : null,
                  ),
                ),
              if (note)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(ctx).pop('note'),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      hasNote
                          ? Icons.sticky_note_2
                          : Icons.sticky_note_2_outlined,
                      size: 18,
                      color: hasNote ? p.accent : p.muted,
                    ),
                  ),
                ),
              if (removable || note)
                Container(
                  width: 1,
                  height: 20,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  color: p.edge,
                ),
              if (removable)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(ctx).pop('remove'),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.delete_outline, size: 18, color: p.muted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Выделить диапазон стихов выбранным цветом: куски выделения
  /// пишутся frag-селекторами (схема 4), стих целиком — как раньше.
  /// Пересечение с существующими выделениями блокирует действие —
  /// занятое место можно только снять. Записям пачки проставляется
  /// общий `created`, чтобы история склеивала их в одно действие.
  Future<void> _highlightRange(String? selText, String color) async {
    final r = _selRange(selText);
    if (r == null) return;
    final lo = r.lo, hi = r.hi;
    final chunks = _selChunks(selText);
    final plan = <({int v, String frag})>[];
    var missed = false;
    for (var v = lo; v <= hi; v++) {
      final raw = _verseRaw(v);
      final trimmed = raw.trim();
      final lead = raw.length - raw.trimLeft().length;
      final chunk = chunks[v]?.trim();
      var frag = '';
      int? s, e;
      // Целый стих (куска нет или он равен стиху) — обычная запись;
      // кусок ищем селектором в тексте стиха. Не нашёлся — стих
      // пропускаем: молча писать целостишовую запись нельзя,
      // иначе промах красит не тот стих целиком.
      if (chunk != null && chunk.isNotEmpty && chunk != trimmed) {
        final rs = await bridgeFragRanges(trimmed, fragJson(chunk, '', ''));
        if (rs.isEmpty) {
          missed = true;
          continue;
        }
        final r = rs.first;
        frag = fragJson(
          trimmed.substring(r.s, r.e),
          trimmed.substring((r.s - 30).clamp(0, trimmed.length), r.s),
          trimmed.substring(r.e, (r.e + 30).clamp(0, trimmed.length)),
        );
        s = r.s + lead;
        e = r.e + lead;
      }
      final clash = (_highlights[v] ?? const <UserEntry>[]).any(
        (ex) =>
            ex.frag.isEmpty ||
            s == null ||
            (_hlFrags[v] ?? const []).any(
              (f) => f.rec.id == ex.id && f.s < e! && f.e > s!,
            ),
      );
      if (clash) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr(
                  'Часть текста уже выделена — сначала снимите выделение',
                  'Part of the text is already highlighted',
                ),
              ),
            ),
          );
        }
        return;
      }
      plan.add((v: v, frag: frag));
    }
    if (plan.isEmpty && missed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'Не удалось найти выделенный текст в стихе',
                'Could not locate the selected text in the verse',
              ),
            ),
          ),
        );
      }
      return;
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (final it in plan) {
      final txt = _verseText(it.v);
      await bridgeEntryAdd(
        kind: 'hl',
        module: _moduleId,
        book: _code,
        chapter: _ch,
        verse: it.v,
        text: color,
        context: txt.substring(0, txt.length.clamp(0, 40)),
        frag: it.frag,
        created: ts,
      );
    }
    await _loadVerseEntries();
  }

  // ---------- построение главы ----------

  /// Сигнатура всего, что влияет на содержимое построенных строк
  /// (кэш [_lineCache]): глава, модули, настройки отображения,
  /// палитра, готовность словаря и конверсий версификаций.
  /// При смене сигнатуры кэш очищается. TTS и выделенный стих в
  /// сигнатуру не входят — кэшируются только вторые строки,
  /// которые от них не зависят.
  void _syncLineCache(Palette p, List<String> ids) {
    final sig = [
      _moduleId,
      _code,
      _ch,
      settings.fontScale,
      settings.fontWeightStep,
      _study,
      settings.layoutMode.index,
      settings.layerStrongs,
      settings.layerFootnotes,
      settings.layerXrefs,
      settings.readingFont.index,
      ids.join('+'),
      _lex != null,
      Object.hash(p.ink, p.muted, p.accent, p.jesus),
      for (final id in ids)
        _convs.containsKey(id) ? _convs[id]?.length ?? 0 : -1,
    ].join('|');
    if (sig != _lineSig) {
      _lineCache.clear();
      _lineSig = sig;
    }
  }

  /// Виджет второй строки из кэша (или построить и запомнить).
  Widget _cachedLine(String key, Widget Function() build) =>
      _lineCache.putIfAbsent(key, build);

  /// Спаны пересоздаются каждый build — их recognizer'ы тоже.
  /// Раз в кадр переносим прежний набор в «старые» и dispose'им
  /// после кадра (дерево с ними к тому моменту размонтировано).
  void _rotateTapRecognizers() {
    if (_tapGcQueued) return;
    _tapGcQueued = true;
    _tapRecognizersOld
      ..clear()
      ..addAll(_tapRecognizers);
    _tapRecognizers.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final r in _tapRecognizersOld) {
        r.dispose();
      }
      _tapRecognizersOld.clear();
      _tapGcQueued = false;
    });
  }

  /// [peek] — входящая страница листания: якоря и общие ключи не
  /// трогаем (иначе дубль GlobalKey с живой страницей).
  List<Widget> _buildChapter(ChapterDoc ch, Palette p, [bool peek = false]) {
    _rotateTapRecognizers();
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
    final cached = ch.pairsCache;
    if (cached != null) return cached;
    var found = false;
    for (final b in ch.blocks) {
      for (final s in b.spans) {
        if (s is TextSpanDoc && s.attrs.contains('gr="')) {
          found = true;
          break;
        }
      }
      if (found) break;
    }
    ch.pairsCache = found;
    return found;
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
    _syncLineCache(p, const []);
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
        if (!peek && chapterNum == null) _verseItemIndex[v] = out.length;
        out.add(
          RepaintBoundary(
            child: Container(
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
                      onTapDown: (d) => _lastTapPos = d.globalPosition,
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
                  Expanded(
                    // В ленте книги ключ главы в сигнатуре один —
                    // главу несёт chapterNum.
                    child: _cachedLine(
                      'P:${chapterNum ?? _ch}:$v',
                      () => _interlinearLine(words[v] ?? const [], p),
                    ),
                  ),
                ],
              ),
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
        child: Listener(
          // Стих под pointer-down в начале выделения — привязка
          // внутристишовых кусков (выделение без маркеров « N »).
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) =>
              _selAnchorVerse = _verseAtPoint(e.position) ?? _selAnchorVerse,
          child: SelectionArea(
            onSelectionChanged: (c) => _selectedText = c?.plainText,
            contextMenuBuilder: _selectionMenu,
          child: _pinchZoom(
            ListView.builder(
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
    // Абзацный режим: стих → индекс блока = индекс элемента ленты.
    if (!peek) {
      verseBlock.forEach((v, i) => _verseItemIndex[v] = i);
    }
    // Первый текстовый блок несёт буквицу — крупную цифру главы
    // (прототип дизайна, приём печатных изданий).
    var capAt = -1;
    for (var i = 0; i < ch.blocks.length; i++) {
      final k = ch.blocks[i].kind;
      if (k == BlockKind.paragraph || k == BlockKind.poetry) {
        capAt = i;
        break;
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
                  children: [
                    if (i == capAt) _chapterCap(p),
                    ..._spansOf(b, p, null, anchorVerses, i == capAt ? 1 : null),
                  ],
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
                  // Красная строка — как в печатных изданиях;
                  // буквица главы заменяет её в первом абзаце.
                  children: [
                    if (i == capAt)
                      _chapterCap(p)
                    else
                      const TextSpan(text: '\u2003'),
                    ..._spansOf(b, p, null, anchorVerses, i == capAt ? 1 : null),
                  ],
                ),
              ),
            ),
          );
      }
    }
    return out;
  }

  /// Буквица главы: крупная цифра в потоке первого блока — базовая
  /// линия на базовой линии первой строки, цвет чернил текста.
  /// Совмещает роль маркера стиха 1 (его номер в блоке скрыт за
  /// буквицей — дубль «1 1» недопустим): тап выбирает стих 1,
  /// акцент — когда стих выделен/выбран.
  InlineSpan _chapterCap(Palette p) => WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _lastTapPos = d.globalPosition,
      onTap: () => _selectVerse(1),
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Semantics(
          label: tr('Глава $_ch, стих 1', 'Chapter $_ch, verse 1'),
          child: Text(
            '$_ch',
            style: TextStyle(
              fontFamily: _textFont(),
              fontSize: _readingSize * settings.fontScale * 3,
              fontWeight: FontWeight.w700,
              color: _selectedVerse == 1 ? p.accent : p.ink,
              height: 1.0,
            ),
          ),
        ),
      ),
    ),
  );

  /// versePerLine: каждый стих — отдельная строка.
  List<Widget> _buildVerseLines(ChapterDoc ch, Palette p, [bool peek = false]) {
    final out = <Widget>[];
    final vg = _verseGroups(ch);
    final verses = vg.groups;
    final order = vg.order;
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
    }
    for (final v in order) {
      if (!peek) _blockKeys.putIfAbsent(v, () => GlobalKey());
      final selected = _selectedVerse == v;
      final hlEntry = _wholeHl(v);
      if (!peek) _verseItemIndex[v] = out.length;
      out.add(
        RepaintBoundary(
          child: Container(
            key: peek ? null : _blockKeys[v],
            color: selected
                ? p.accent.withValues(alpha: 0.08)
                : (hlEntry != null
                      ? highlightColor(hlEntry.text).withValues(alpha: 0.2)
                      : null),
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
                    onTapDown: (d) => _lastTapPos = d.globalPosition,
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
                              fontSize: 19 * settings.fontScale,
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
                                  Icon(
                                    Icons.bookmark,
                                    size: 10,
                                    color: p.accent,
                                  ),
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
                      onTapDown: (d) => _lastTapPos = d.globalPosition,
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
        ),
      );
    }
    return out;
  }

  /// Стих -> плоский текст главы (без номеров и сносок) —
  /// для второго перевода в строчном сравнении.
  Map<int, String> _plainVerses(ChapterDoc ch) {
    final cached = ch.plainCache;
    if (cached != null) return cached;
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
    final res = {for (final e in out.entries) e.key: e.value.toString().trim()};
    ch.plainCache = res;
    return res;
  }

  /// Слова оригинала по стихам — спаны style='w' (strong/lemma в attrs).
  Map<int, List<TextSpanDoc>> _wordSpans(ChapterDoc ch) {
    final cached = ch.wordCache;
    if (cached != null) return cached;
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
    ch.wordCache = out;
    return out;
  }

  /// Группировка спанов главы по стихам: порядок стихов и их спаны
  /// (без маркеров номеров) — общая часть _buildVerseLines и
  /// _buildInterleaved; считается один раз на главу.
  ({List<int> order, Map<int, List<SpanDoc>> groups}) _verseGroups(
    ChapterDoc ch,
  ) {
    final cached = ch.verseGroupsCache;
    if (cached != null) return cached;
    final groups = <int, List<SpanDoc>>{};
    final order = <int>[];
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
          groups.putIfAbsent(cur, () => []);
          order.add(cur);
        } else if (cur >= 0) {
          groups[cur]!.add(s);
        }
      }
    }
    final res = (order: order, groups: groups);
    ch.verseGroupsCache = res;
    return res;
  }

  /// Лента подстрочника: каждое слово — колонка «слово оригинала /
  /// краткая глосса». Для иврита — RTL. [label] — ярлык перевода
  /// при нескольких строках сравнения.
  Widget _interlinearLine(
    List<TextSpanDoc> words,
    Palette p, [
    String? lang,
    String? label,
  ]) {
    lang ??= '';
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
    final body = Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: wrap,
    );
    if (label == null) return body;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _moduleTag(label, p),
        Expanded(child: body),
      ],
    );
  }

  /// Ярлык перевода перед строкой сравнения (режим 3+).
  Widget _moduleTag(String label, Palette p) => Padding(
    padding: const EdgeInsets.only(right: 6, top: 1),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10 * settings.fontScale,
        fontWeight: FontWeight.w700,
        color: p.accent.withValues(alpha: 0.7),
      ),
    ),
  );

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

  /// Пересчитать кэш конверсии версификаций для текущей главы —
  /// один раз на комбинацию «книга:глава:основной->второй»
  /// (вопрос 8). Результат — в [_conv]; главы второго модуля,
  /// куда ведут соответствия, догружаются лениво.
  void _ensureConv([String? targetId]) {
    final id = targetId ?? _compareModuleId;
    final main = _module;
    final second = _mods[id];
    if (main == null || second == null) return;
    final key = '$_code:$_ch:$_moduleId->$id';
    if (_convKeys[id] == key) return;
    _convKeys[id] = key;
    _convs[id] = null;
    final fv = main.versification;
    final tv = second.versification;
    // Версификация неизвестна или та же — короткий путь без моста.
    if (fv.isEmpty || tv.isEmpty || fv == tv) return;
    final maxV = main.verseCount(_code, _ch);
    () async {
      final map = <int, List<CvPoint>>{};
      for (var v = 0; v <= maxV; v++) {
        map[v] = await convertVerse(_code, _ch, v, fv, tv);
      }
      // Соответствия в других главах — подгрузить эти главы.
      for (final pts in map.values) {
        for (final p in pts) {
          if (p.book != _code || p.chapter != _ch) {
            await second.ensureChapter(p.book, p.chapter);
          }
        }
      }
      if (mounted && _convKeys[id] == key) {
        _rebuild(() => _convs[id] = map);
      }
    }();
  }

  /// Координаты стиха [v] основного перевода в модуле [targetId]
  /// (по умолчанию — второй перевод) — из кэша конверсии; до её
  /// готовности (или при одинаковых версификациях) — тот же номер.
  List<CvPoint> _targetsOf(int v, [String? targetId]) =>
      _convs[targetId ?? _compareModuleId]?[v] ??
      [(book: _code, chapter: _ch, verse: v)];

  /// Тексты стихов второго перевода по координатам [targets]:
  /// каждая — со своим номером в собственной версификации.
  /// Стихи без текста пропускаются.
  List<({CvPoint point, String text})> _secondTexts(
    ModuleDoc second,
    Map<String, Map<int, String>> plainCache,
    List<CvPoint> targets,
  ) {
    final out = <({CvPoint point, String text})>[];
    for (final t in targets) {
      final plain = plainCache.putIfAbsent('${t.book}:${t.chapter}', () {
        final c = second.chapter(t.book, t.chapter);
        return c == null ? const {} : _plainVerses(c);
      });
      final txt = plain[t.verse];
      if (txt != null && txt.isNotEmpty) {
        out.add((point: t, text: txt));
      }
    }
    return out;
  }

  /// Слова подстрочника второго модуля по координатам [targets]
  /// (несколько соответствующих стихов — слова идут подряд).
  List<TextSpanDoc> _secondWordsOf(
    ModuleDoc second,
    Map<String, Map<int, List<TextSpanDoc>>> wordCache,
    List<CvPoint> targets,
  ) {
    final out = <TextSpanDoc>[];
    for (final t in targets) {
      final words = wordCache.putIfAbsent('${t.book}:${t.chapter}', () {
        final c = second.chapter(t.book, t.chapter);
        return c == null ? const {} : _wordSpans(c);
      });
      out.addAll(words[t.verse] ?? const []);
    }
    return out;
  }

  /// Строчное сравнение: стих основного перевода, под ним —
  /// соответствующие (по версификации) стихи каждого перевода из
  /// [_compareIds] (список модулей слоя, ADR 0020). У модуля со
  /// словами Стронга (оригиналы OSHB/UGNT) строка рисуется как
  /// подстрочник слово-к-слову.
  List<Widget> _buildInterleaved(ChapterDoc ch, Palette p) {
    final ids = _compareIds;
    // Кэши по каждому модулю: плоский текст / слова по главам
    // ('книга:глава' -> ...), чтобы соответствия в соседних главах
    // не пересчитывались.
    final mods = <String, ModuleDoc>{};
    final plainCaches = <String, Map<String, Map<int, String>>>{};
    final wordCaches = <String, Map<String, Map<int, List<TextSpanDoc>>>>{};
    final interlinears = <String>{};
    for (final id in ids) {
      final m = _mods[id];
      if (m == null) {
        _load(id);
        continue;
      }
      _ensureConv(id);
      final ch2 = m.chapter(_code, _ch);
      if (ch2 == null) {
        _ensureChapter(m, _code, _ch);
        continue;
      }
      mods[id] = m;
      final pc = {'$_code:$_ch': _plainVerses(ch2)};
      final wc = {'$_code:$_ch': _wordSpans(ch2)};
      plainCaches[id] = pc;
      wordCaches[id] = wc;
      if (wc['$_code:$_ch']!.isNotEmpty) interlinears.add(id);
    }
    if (interlinears.isNotEmpty) _ensureLex();
    _syncLineCache(p, ids);
    final out = <Widget>[];
    final vg = _verseGroups(ch);
    final verses = vg.groups;
    final order = vg.order;
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
    }
    // Надписание (стих 0, вопрос 9): отдельная строка над первым
    // стихом — подпись «надписание» и текст стиха 0 каждой части
    // сравнения (у второго — по конверсии, нет стиха 0 — прочерк).
    final supSeconds = [
      for (final id in ids)
        (
          id: id,
          texts: mods[id] == null
              ? const <({CvPoint point, String text})>[]
              : _secondTexts(mods[id]!, plainCaches[id]!, _targetsOf(0, id)),
        ),
    ];
    final supMain = [
      for (final s in verses[0] ?? const <SpanDoc>[])
        if (s is TextSpanDoc) s.text,
    ].join().trim();
    final hasSup =
        supMain.isNotEmpty || supSeconds.any((s) => s.texts.isNotEmpty);
    if (hasSup) {
      out.add(_superscriptionRow(supMain, supSeconds, p));
    }
    for (final v in order) {
      if (v == 0 && hasSup) continue;
      _blockKeys.putIfAbsent(v, () => GlobalKey());
      final selected = _selectedVerse == v;
      final hlEntry = _wholeHl(v);
      _verseItemIndex[v] = out.length;
      out.add(
        RepaintBoundary(
          child: Container(
            key: _blockKeys[v],
            color: selected
                ? p.accent.withValues(alpha: 0.08)
                : (hlEntry != null
                      ? highlightColor(hlEntry.text).withValues(alpha: 0.2)
                      : null),
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
                        onTapDown: (d) => _lastTapPos = d.globalPosition,
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
                                      Icon(
                                        Icons.label,
                                        size: 9,
                                        color: p.muted,
                                      ),
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
                // Строки переводов сравнения: соответствия по
                // версификации, приглушённые; у модулей оригинала —
                // подстрочник слово-к-слову (по конвертированной ссылке).
                // При двух и более модулях — ярлык имени перевода.
                for (final id in ids)
                  _cachedLine(
                    'S:$id:$v',
                    () => interlinears.contains(id)
                        ? Padding(
                            padding: const EdgeInsets.only(
                              left: 30,
                              top: 2,
                              bottom: 4,
                            ),
                            child: _interlinearLine(
                              _secondWordsOf(
                                mods[id]!,
                                wordCaches[id]!,
                                _targetsOf(v, id),
                              ),
                              p,
                              mods[id]!.language,
                              ids.length > 1 ? moduleName(id) : null,
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.only(
                              left: 30,
                              top: 2,
                              bottom: 4,
                            ),
                            child: Text.rich(
                              TextSpan(
                                style: TextStyle(
                                  fontFamily: readingFontFamily(
                                    settings.readingFont,
                                  ),
                                  fontSize: 15 * settings.fontScale,
                                  color: p.muted,
                                  fontStyle: FontStyle.italic,
                                  height: 1.5,
                                ),
                                children: _secondLineSpans(
                                  v,
                                  mods[id],
                                  plainCaches[id] ?? const {},
                                  p,
                                  ids.length > 1 ? moduleName(id) : null,
                                ),
                              ),
                            ),
                          ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return out;
  }

  /// Спаны второй строки сравнения для стиха [v]: каждый
  /// соответствующий стих второго перевода — со своим номером
  /// «глава:стих» маленьким приглушённым префиксом, когда номер
  /// отличается от основного; при равном — без префикса.
  /// Пустое соответствие — «…» (как раньше при отсутствии стиха).
  List<InlineSpan> _secondLineSpans(
    int v,
    ModuleDoc? secondMod,
    Map<String, Map<int, String>> plainCache,
    Palette p, [
    String? label,
  ]) {
    final items = secondMod == null
        ? const <({CvPoint point, String text})>[]
        : _secondTexts(secondMod, plainCache, _targetsOf(v, secondMod.id));
    final prefixStyle = TextStyle(
      fontSize: 11 * settings.fontScale,
      color: p.muted.withValues(alpha: 0.7),
      fontStyle: FontStyle.normal,
      fontWeight: FontWeight.w600,
    );
    if (items.isEmpty) {
      return [
        if (label != null)
          TextSpan(
            text: '$label ',
            style: prefixStyle.copyWith(color: p.accent.withValues(alpha: 0.7)),
          ),
        const TextSpan(text: '…'),
      ];
    }
    return [
      if (label != null)
        TextSpan(
          text: '$label ',
          style: prefixStyle.copyWith(color: p.accent.withValues(alpha: 0.7)),
        ),
      for (var i = 0; i < items.length; i++) ...[
        if (items[i].point.chapter != _ch || items[i].point.verse != v)
          TextSpan(
            text: '${items[i].point.chapter}:${items[i].point.verse} ',
            style: prefixStyle,
          ),
        TextSpan(text: items[i].text),
        if (i + 1 < items.length) const TextSpan(text: ' '),
      ],
    ];
  }

  /// Строка надписания (стих 0, вопрос 9, вариант А): подпись
  /// «надписание» + текст стиха 0 основного и второго перевода
  /// (у перевода без стиха 0 — прочерк).
  /// Строка надписания (стих 0, вопрос 9, вариант А): подпись
  /// «надписание» + текст стиха 0 основного и каждого перевода
  /// сравнения (у перевода без стиха 0 — прочерк).
  Widget _superscriptionRow(
    String mainText,
    List<({String id, List<({CvPoint point, String text})> texts})> seconds,
    Palette p,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('надписание', 'superscription'),
            style: TextStyle(
              fontSize: 11 * settings.fontScale,
              color: p.muted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 2),
          if (mainText.isNotEmpty)
            Text(mainText, style: _baseStyle(p))
          else
            Text('—', style: TextStyle(color: p.muted)),
          for (final s in seconds)
            Text(
              s.texts.isEmpty
                  ? '—'
                  : [
                      if (seconds.length > 1) '[${moduleName(s.id)}]',
                      for (final t in s.texts)
                        '${t.point.chapter}:${t.point.verse} ${t.text}',
                    ].join(' '),
              style: TextStyle(
                fontFamily: readingFontFamily(settings.readingFont),
                fontSize: 15 * settings.fontScale,
                color: p.muted,
                fontStyle: FontStyle.italic,
                height: 1.5,
              ),
            ),
        ],
      ),
    );
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
