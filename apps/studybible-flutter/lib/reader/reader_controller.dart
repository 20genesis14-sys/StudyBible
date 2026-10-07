part of '../screens/reading_screen.dart';

/// Действия экрана чтения с записями пользователя.
extension _ReaderController on _ReadingScreenState {
  String _verseText(int v) {
    final ch = _module?.chapter(_code, _ch);
    if (ch == null) return '';
    final buf = StringBuffer();
    var inside = false;
    for (final b in ch.blocks) {
      for (final s in b.spans) {
        if (s is VerseSpanDoc) {
          inside = s.verse == v;
        } else if (inside && s is TextSpanDoc) {
          buf.write(s.text);
        }
      }
    }
    return buf.toString().trim();
  }

  String _refOf(int v) => '${_titleOf(_code)} $_ch:$v';

  /// Закладка на стих (kind=mark в UserData): ставится и снимается
  /// повторным действием.
  Future<void> _toggleMark(int v) async {
    final existing = _verseMarks[v];
    if (existing != null) {
      await bridgeEntryRemove(existing.id);
    } else {
      final txt = _verseText(v);
      await bridgeEntryAdd(
        kind: 'mark',
        module: _moduleId,
        book: _code,
        chapter: _ch,
        verse: v,
        text: '',
        context: txt.substring(0, txt.length.clamp(0, 40)),
      );
    }
    await _loadVerseEntries();
  }

  /// Диалог тегов стиха (kind=tag, text — имена через запятую,
  /// одна запись на стих; пустой список — записи нет).
  Future<void> _editTags(int v) async {
    final existing = _tagEntries[v];
    final text = await showDialog<String>(
      context: context,
      builder: (_) =>
          TagsDialog(ref: _refOf(v), initial: _tagsOf(v).join(', ')),
    );
    if (text == null) return;
    final cleaned = [
      for (final t in text.split(','))
        if (t.trim().isNotEmpty) t.trim(),
    ].join(',');
    if (existing != null) {
      if (cleaned.isEmpty) {
        await bridgeEntryRemove(existing.id);
      } else {
        await bridgeEntryUpdate(existing.id, cleaned);
      }
    } else if (cleaned.isNotEmpty) {
      final txt = _verseText(v);
      await bridgeEntryAdd(
        kind: 'tag',
        module: _moduleId,
        book: _code,
        chapter: _ch,
        verse: v,
        text: cleaned,
        context: txt.substring(0, txt.length.clamp(0, 40)),
      );
    }
    await _loadVerseEntries();
  }

  /// Выделить/снять выделение стиха (kind=hl в UserData).
  Future<void> _toggleHighlight(int v) async {
    final existing = _highlights[v];
    if (existing != null) {
      await bridgeEntryRemove(existing.id);
    } else {
      await bridgeEntryAdd(
        kind: 'hl',
        module: _moduleId,
        book: _code,
        chapter: _ch,
        verse: v,
        text: 'yellow',
        context: _verseText(v).substring(0, _verseText(v).length.clamp(0, 40)),
      );
    }
    await _loadVerseEntries();
  }

  /// Диалог заметки к стиху: текст + вложения (картинки, аудио).
  /// Записью заведует сам диалог (вложениям нужен id записи
  /// сразу при добавлении файла, до «Сохранить»).
  Future<void> _editNote(int v) async {
    final existing = _verseNotes[v];
    final action = await showDialog<String>(
      context: context,
      builder: (_) => NoteDialog(
        ref: _refOf(v),
        entry: existing,
        tagEntry: _tagEntries[v],
        moduleId: _moduleId,
        book: _code,
        chapter: _ch,
        verse: v,
        contextText: _verseText(v)
            .substring(0, _verseText(v).length.clamp(0, 40)),
      ),
    );
    if (action == 'save' || action == 'delete') {
      await _loadVerseEntries();
    }
  }

  Future<void> _copyVerse(int v) async {
    await Clipboard.setData(
      ClipboardData(text: '${_refOf(v)} — ${_verseText(v)}'),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Стих скопирован', 'Verse copied'))),
      );
    }
  }

  Future<void> _shareVerse(int v) async {
    await Clipboard.setData(
      ClipboardData(
        text:
            '${_refOf(v)}\n${_verseText(v)}\n(${moduleName(_moduleId)})',
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('Текст скопирован для отправки', 'Text copied for sharing'),
          ),
        ),
      );
    }
  }

  /// Прокрутить follower пропорционально leader (оба направления
  /// прикрыты флагом от зацикливания). Синхронизация плавная:
  /// короткая анимация вместо jumpTo — вторая колонка «тянется»
  /// за первой, а не дёргается рывками.
  void _syncScroll(ScrollController leader, ScrollController follower) {
    if (!_compare || _syncingScroll) return;
    if (!leader.hasClients || !follower.hasClients) return;
    // Кадр перестройки режима: контроллер может быть у двух Scrollable.
    if (leader.positions.length != 1 || follower.positions.length != 1) return;
    final max = leader.position.maxScrollExtent;
    final fmax = follower.position.maxScrollExtent;
    if (max <= 0 || fmax <= 0) return;
    final target = (leader.offset / max * fmax).clamp(0.0, fmax);
    if ((follower.offset - target).abs() < 2) return;
    _syncingScroll = true;
    follower
        .animateTo(
          target,
          duration: const Duration(milliseconds: 90),
          curve: Curves.linear,
        )
        .whenComplete(() => _syncingScroll = false);
  }

  /// Перечитать выделения и заметки текущей главы из userdata.db.
  Future<void> _loadVerseEntries() async {
    final hl = await bridgeEntriesList('hl', module: _moduleId);
    final nt = await bridgeEntriesList('note', module: _moduleId);
    final mk = await bridgeEntriesList('mark', module: _moduleId);
    final tg = await bridgeEntriesList('tag', module: _moduleId);
    if (!mounted) return;
    _rebuild(() {
      _highlights
        ..clear()
        ..addEntries(
          hl
              .where((e) => e.book == _code && e.chapter == _ch)
              .map((e) => MapEntry(e.verse, e)),
        );
      _verseNotes
        ..clear()
        ..addEntries(
          nt
              .where((e) => e.book == _code && e.chapter == _ch)
              .map((e) => MapEntry(e.verse, e)),
        );
      _verseMarks
        ..clear()
        ..addEntries(
          mk
              // Записи истории (text 'hist*') — не закладки, маркеры
              // на стихи по ним не ставим.
              .where(
                (e) =>
                    e.book == _code &&
                    e.chapter == _ch &&
                    !e.text.startsWith('hist'),
              )
              .map((e) => MapEntry(e.verse, e)),
        );
      _tagEntries
        ..clear()
        ..addEntries(
          tg
              .where((e) => e.book == _code && e.chapter == _ch)
              .map((e) => MapEntry(e.verse, e)),
        );
    });
  }

  /// Теги стиха (список по запятой из одной tag-записи).
  List<String> _tagsOf(int v) {
    final e = _tagEntries[v];
    if (e == null) return const [];
    return [
      for (final t in e.text.split(','))
        if (t.trim().isNotEmpty) t.trim(),
    ];
  }

  Future<void> _load(String id) async {
    final m = await loadModule(id);
    if (!mounted) return;
    // Для .sb-модулей глава подгружается лениво через мост.
    await m.ensureChapter(_code, _ch);
    if (mounted) _rebuild(() => _mods[id] = m);
    // Глава подгрузилась — второй шанс прокрутить к целевому стиху
    // (при push по ссылке ключи появляются только после загрузки).
    if (id == _moduleId && mounted) {
      _scrollToVerse(widget.verse ?? progress.lastVerse['$_code:$_ch']);
    }
  }

  /// Подгрузить текущую главу для модуля и перерисоваться.
  void _ensureChapter(ModuleDoc m, String code, int ch) {
    m.ensureChapter(code, ch).then((_) {
      if (mounted) _rebuild(() {});
    });
  }

  // ---------- чтение вслух (TTS) ----------

  String get _ttsLang => switch (_module?.language) {
    'he' || 'hbo' || 'arc' => 'he-IL',
    'grc' || 'el' => 'el-GR',
    'en' => 'en-US',
    _ => 'ru-RU',
  };

  Future<void> _toggleTts() async {
    if (_ttsPlaying) {
      _stopTts();
      return;
    }
    final ch = _module?.chapter(_code, _ch);
    if (ch == null) return;
    final verses = _plainVerses(ch);
    if (verses.isEmpty) return;
    await _ttsService.start(
      language: _ttsLang,
      verses: verses.entries.toList(),
    );
  }

  void _pauseTts() => _ttsService.pause();
  void _resumeTts() => _ttsService.resume();

  /// Переход ползунком плеера на стих с индексом [i]: на паузе
  /// только сдвигает позицию, при игре — сразу озвучивает его.
  void _slideTts(int i) => _ttsService.slide(i);

  /// Перемотка на [dir] стихов. На паузе — просто сдвигает
  /// позицию, при игре — сразу озвучивает новый стих.
  void _seekTts(int dir) => _ttsService.seek(dir);

  void _stopTts() => _ttsService.stop();

  /// Контекст для прокрутки к стиху [v]. Якорь-ключ висит на самом
  /// номере стиха внутри текста — обычно попадание точное. Если у
  /// стиха контекста нет (не построен), берём ближайший построенный
  /// стих до целевого.
  /// [prefix] — «глава:» для книжной ленты, пусто для главы.
  BuildContext? _ctxForVerse(
    Map<dynamic, GlobalKey> keys,
    String prefix,
    int v,
  ) {
    BuildContext? best;
    var bestN = -1;
    keys.forEach((k, key) {
      final ks = k.toString();
      final n = prefix.isEmpty
          ? int.tryParse(ks)
          : (ks.startsWith(prefix)
                ? int.tryParse(ks.substring(prefix.length))
                : null);
      if (n == null || n > v || n <= bestN) return;
      final c = key.currentContext;
      if (c != null) {
        bestN = n;
        best = c;
      }
    });
    return best;
  }

  void _scrollToVerse(int? v) {
    if (v == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (settings.layoutMode == LayoutMode.book) {
        // Лента книги ленивая — всегда через итеративный поиск,
        // даже если якорь уже построен (главы-заглушки сдвигают его).
        _seekVerseBook(_code, _ch, v);
        return;
      }
      final ctx = _ctxForVerse(_blockKeys, '', v);
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          alignment: 0.15,
        );
      }
    });
  }

  /// Итеративная прокрутка к стиху в ленте книги. Главы строятся
  /// лениво и сначала висят низкими заглушками: якорь целевого стиха
  /// может появиться рано, но «уплыть» вниз, когда главы выше
  /// подгрузятся и раздвинут ленту. Поэтому цикл: пока якоря нет —
  /// прыгаем по оценке высоты главы; когда появился — следим за
  /// стабильностью его экранной позиции и докручиваем, пока лента
  /// не устоится (пара кадров без сдвига).
  Future<void> _seekVerseBook(String code, int ch, int v) async {
    if (_seeking) return;
    _seeking = true;
    try {
      double? anchorY;
      var stable = 0;
      var lastEst = -1.0;
      var sameEst = 0;
      for (var i = 0; i < 40 && mounted; i++) {
        // endOfFrame на статичном экране висит: кадр ждут, но
        // никто его не заказывает — прыжки меняют pixels в памяти,
        // а ListView не переразвёрстывается и главы не строятся.
        // Поэтому кадр заказываем сами — видимые главы достроятся,
        // ключи якорей оживут. Ждём дольше кадра: развёрстка ленты
        // тяжёлая и может не успеть к обычному таймауту.
        final frame = Completer<void>();
        WidgetsBinding.instance.scheduleFrameCallback((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) => frame.complete());
        });
        await frame.future.timeout(
          const Duration(milliseconds: 400),
          onTimeout: () {},
        );
        if (!mounted || !_scroll.hasClients) return;
        if (_code != code || _ch != ch) return; // ушли на другую главу
        final pos = _scroll.position;
        final ctx = _ctxForVerse(_bookVerseKeys, '$ch:', v);
        if (ctx != null && ctx.mounted) {
          // Якорь построен и развёрнут. Его позиция ещё может плыть:
          // главы выше догружаются и раздвигают ленту — докручиваем,
          // пока экранная позиция не устоится (пара кадров без сдвига).
          final ro = ctx.findRenderObject();
          final y = ro is RenderBox ? ro.localToGlobal(Offset.zero).dy : null;
          // Комфортная зона 10–60% высоты: выше — якорь уплывает
          // под стеклянную панель, ниже — за нижнюю панель/экран.
          if (y == null ||
              y < pos.viewportDimension * 0.10 ||
              y > pos.viewportDimension * 0.6) {
            // ensureVisible здесь не срабатывает: его анимация
            // тикает по кадрам, а кадры во время догрузки ленты
            // редкие (~2 fps) — анимация замирает на старте.
            // Докручиваем напрямую: позиция якоря известна точно.
            final target =
                (pos.pixels + (y ?? 0) - pos.viewportDimension * 0.15).clamp(
                  0.0,
                  pos.maxScrollExtent,
                );
            pos.jumpTo(target);
          }
          if (y != null && anchorY != null && (y - anchorY).abs() < 1) {
            stable++;
            if (stable >= 2) {
              return; // позиция устоялась
            }
          } else {
            stable = 0;
          }
          anchorY = y;
          continue;
        }
        // Якоря нет: целевая глава не развёрнута (или не видна).
        // Прыгаем к её оценочной позиции: доля ленты по индексу главы.
        // Оценка абсолютная и сама точнеет по мере загрузки глав —
        // не накапливает ошибку как относительный шаг.
        var nearest = 0;
        for (final e in _bookVerseKeys.entries) {
          if (e.value.currentContext == null) continue;
          final c = int.tryParse(e.key.split(':').first) ?? 0;
          if (nearest == 0 || (c - ch).abs() < (nearest - ch).abs()) {
            nearest = c;
          }
        }
        if (nearest == ch) {
          // Глава развёрнута, а якоря стиха нет — дальше некуда.
          return;
        }
        final total = _module?.bookByCode(code)?.chapters ?? ch;
        double target;
        if (nearest != 0 && (ch - nearest).abs() <= 2) {
          // Целевая глава рядом: индексная оценка уже врёт
          // (главы неравномерны и пинг-понгят прыжки) — идём
          // экран за экраном, пока её якоря не оживут.
          target = pos.pixels + (ch - nearest).sign * pos.viewportDimension;
        } else {
          // Далеко или живых глав нет: прыжок к оценочной
          // позиции — доля ленты по индексу главы. Оценка
          // абсолютная и точнеет по мере догрузки глав.
          target = pos.maxScrollExtent * (ch - 1) / (total <= 0 ? 1 : total);
        }
        target = target.clamp(0.0, pos.maxScrollExtent);
        if ((target - lastEst).abs() < 1) {
          sameEst++;
          if (sameEst >= 4) {
            return; // цель устоялась, якорь так и не появился
          }
        } else {
          sameEst = 0;
        }
        lastEst = target;
        // Шаг ограничен ~12 экранами за раз.
        final step = (target - pos.pixels).clamp(
          -pos.viewportDimension * 12,
          pos.viewportDimension * 12,
        );
        _scroll.jumpTo(pos.pixels + step);
      }
    } finally {
      _seeking = false;
    }
  }

  // ---------- навигация по главам/книгам ----------

  String _titleOf(String code) =>
      _module?.bookByCode(code)?.title ?? bookShort(code);

  /// Название книги для верхней панели: длинные имена режем до
  /// ~12 знаков с многоточием — иначе они выталкивают пилюлю
  /// поиска за край экрана (узкие телефоны).
  String _titleCapped() {
    final t = _titleOf(_code);
    if (t.length <= 13) return t;
    return '${t.substring(0, 12).trimRight()}…';
  }

  /// Цель перехода _go без побочек: (код книги, глава, баннер края
  /// книги) — null на краю канона. Та же цель у листания-подгляда.
  (String, int, String?)? _goTarget(int dir) {
    var code = _code;
    var ch = _ch + dir;
    // Порядок книг берём из модуля — так работают и неканонические,
    // которых нет в каталоге 66.
    final books = _module?.books ?? const <BookDoc>[];
    final midx = books.indexWhere((b) => b.code == code);
    // Режим «книга»: лента охватывает всю книгу — свайпы листают книги.
    if (settings.layoutMode == LayoutMode.book) {
      if (midx >= 0) {
        final bi = midx + dir;
        if (bi < 0 || bi >= books.length) return null;
        return (books[bi].code, 1, null);
      }
      final bi = bookIndexOf(code) + dir;
      if (bi < 0 || bi >= kCatalog.length) return null;
      return (kCatalog[bi].$1, 1, null);
    }
    final count = _module?.bookByCode(code)?.chapters ?? _ch;
    if (ch > count && midx >= 0 && midx < books.length - 1) {
      final next = books[midx + 1];
      return (
        next.code,
        1,
        tr(
          'Конец «${_titleOf(code)}» → «${_titleOf(next.code)}»',
          'End of "${_titleOf(code)}" → "${_titleOf(next.code)}"',
        ),
      );
    }
    if (ch < 1 && midx > 0) {
      final prev = books[midx - 1];
      return (
        prev.code,
        prev.chapters,
        tr(
          'Конец «${_titleOf(prev.code)}» → «${_titleOf(code)}»',
          'End of "${_titleOf(prev.code)}" → "${_titleOf(code)}"',
        ),
      );
    }
    if (ch > count || ch < 1) return null;
    return (code, ch, null);
  }

  void _go(int dir) {
    final t = _goTarget(dir);
    if (t == null) return;
    final (code, ch, banner) = t;
    // Свайп — переход в стеке рабочего места (ADR 0019).
    final loc = Location.verse(
      moduleId: _moduleId,
      book: code,
      chapter: ch,
      pane: _paneSnapshot(),
    );
    workspace.go(loc);
    _applyLocation(loc, banner);
  }
}
