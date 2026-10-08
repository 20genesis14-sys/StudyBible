part of '../screens/reading_screen.dart';

/// Одна панель чтения и сравнение переводов.
extension _ReaderPane on _ReadingScreenState {
  Widget _readingBody(ChapterDoc? ch, Palette p, bool wide) {
    final maxW = settings.columnWidth == ColumnWidth.reading && wide
        ? 720.0
        : double.infinity;
    Widget content;
    if (settings.layoutMode == LayoutMode.book &&
        !_interleaved &&
        !_compare &&
        !_study) {
      // «Бесконечная книга»: вся книга одной лентой. В режиме
      // «Изучение» лента уступает построчной вёрстке главы.
      return _bookFeed(p, wide);
    }
    if (ch == null) {
      content = Center(
        child: Text(
          tr(
            'Эта глава не выгружена в прототип',
            'This chapter is not available in the prototype',
          ),
          style: TextStyle(color: p.muted),
        ),
      );
    } else {
      // Ленивая лента главы (08.10.2026, вариант 1): строки стихов
      // строятся только в видимой области — длинные главы в режиме
      // изучения/сравнения не создают ~20 тыс. рендер-объектов.
      // Якоря стихов — индекс элемента (_verseItemIndex), прокрутка —
      // _seekVerseChapter. Список виджетов собирается целиком
      // (объекты дешёвые), ленивыми остаются Element/RenderObject.
      _verseItemIndex.clear();
      final items = <Widget>[
        // Заголовок «Книга · Глава N» в начале главы —
        // тот же, что на peek-странице листания.
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Text(
            '${_titleOf(_code)} · '
            '${tr('Глава $_ch', 'Chapter $_ch')}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: readingFontFamily(settings.readingFont),
              fontSize: 19 * settings.fontScale,
              fontWeight: FontWeight.w800,
              color: _verseColor(p),
            ),
          ),
        ),
        ..._interleaved ? _buildInterleaved(ch, p) : _buildChapter(ch, p),
      ];
      _itemsTotal = items.length;
      content = Listener(
        // Ctrl + колёсико — масштаб шрифта.
        onPointerSignal: (e) {
          if (e is PointerScrollEvent &&
              HardwareKeyboard.instance.isControlPressed) {
            final next = (settings.fontScale - e.scrollDelta.dy / 600).clamp(
              0.8,
              1.6,
            );
            settings.update(() => settings.fontScale = next);
          }
        },
        child: _pinchZoom(
          SelectionArea(
            onSelectionChanged: (c) => _selectedText = c?.plainText,
            contextMenuBuilder: _selectionMenu,
            child: ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                wide ? 48 : 20,
                // Когда сверху уже стоит полоса выбора перевода
                // (строчное сравнение / мобильный compare), отступ
                // под панель не нужен — иначе двойной зазор.
                _interleaved || (_compare && !wide) ? 12 : _topClear(),
                wide ? 48 : 20,
                wide ? 20 : _bottomClear(),
              ),
              itemCount: items.length,
              itemBuilder: (_, i) => Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: SizedBox(width: double.infinity, child: items[i]),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (_interleaved) {
      // Строчное сравнение: одна лента, выбор второго перевода сверху.
      return Column(
        children: [
          Container(
            width: double.infinity,
            color: p.card,
            // Полоса выбора — НИЖЕ верхней панели: контролам нельзя
            // быть под ней и под строкой состояния. Высота панели —
            // строка состояния + ~56 (прогресс + ряд кнопок).
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: _topClear(),
              bottom: 6,
            ),
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
          Expanded(child: content),
        ],
      );
    }
    if (_compare && !wide) {
      // мобильная: переключатель перевода сверху
      final secondMod = _mods[_compareModuleId];
      return Column(
        children: [
          Padding(
            // Ниже верхней панели и строки состояния.
            padding: EdgeInsets.only(
              left: 8,
              right: 8,
              top: _topClear(),
              bottom: 8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                        value: 'main',
                        label: Text(tr('Основной', 'Primary')),
                      ),
                      ButtonSegment(
                        value: 'second',
                        label: Text(
                          _shortModuleName(_compareModuleId),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    selected: {_mobilePane},
                    onSelectionChanged: (s) =>
                        _rebuild(() => _mobilePane = s.first),
                  ),
                ),
                // Выбор второго перевода для сравнения.
                IconButton(
                  tooltip: tr(
                    'Выбрать второй перевод',
                    'Choose second translation',
                  ),
                  icon: Icon(
                    Icons.library_books_outlined,
                    size: 20,
                    color: p.muted,
                  ),
                  onPressed: _pickCompareModule,
                ),
              ],
            ),
          ),
          Expanded(
            child: _mobilePane == 'second'
                ? _compareColumn(secondMod, p)
                : content,
          ),
        ],
      );
    }
    return content;
  }

  /// Pinch-zoom: щипок двумя пальцами масштабирует основной текст
  /// (settings.fontScale, те же пределы 0.8–1.6, что у Ctrl+колёсика).
  /// Во время жеста — живой предпросмотр без записи, сохранение —
  /// по отпускании пальцев.
  ///
  /// Реализовано на Listener, а не GestureDetector: распознаватель
  /// жестов забрал бы однопальцевое перетаскивание у SelectionArea и
  /// прокрутки (та же причина, что и у ReaderPageSwipe).
  Widget _pinchZoom(Widget child) {
    void end() {
      _pinchPtrs.clear();
      if (_pinching) {
        _pinching = false;
        settings.save();
      }
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (_pinchPtrs.length < 2) _pinchPtrs[e.pointer] = e.position;
        if (_pinchPtrs.length == 2) {
          final p = _pinchPtrs.values.toList();
          _pinchDist0 = (p[0] - p[1]).distance;
          _pinchFont = settings.fontScale;
          _pinching = _pinchDist0 > 0;
        }
      },
      onPointerMove: (e) {
        if (!_pinchPtrs.containsKey(e.pointer)) return;
        _pinchPtrs[e.pointer] = e.position;
        if (!_pinching || _pinchPtrs.length < 2) return;
        final p = _pinchPtrs.values.toList();
        final d = (p[0] - p[1]).distance;
        final next = (_pinchFont * d / _pinchDist0).clamp(0.8, 1.6);
        if (next != settings.fontScale) {
          settings.preview(() => settings.fontScale = next.toDouble());
        }
      },
      onPointerUp: (e) {
        _pinchPtrs.remove(e.pointer);
        if (_pinchPtrs.length < 2) end();
      },
      onPointerCancel: (e) {
        _pinchPtrs.remove(e.pointer);
        if (_pinchPtrs.length < 2) end();
      },
      child: child,
    );
  }

  String _shortModuleName(String id) {
    final n = moduleName(id);
    final i = n.indexOf(' (');
    final base = i > 0 ? n.substring(0, i) : n;
    return base.length > 22 ? '${base.substring(0, 22)}…' : base;
  }

  /// Выбор второго перевода сравнения на телефоне (нижний лист).
  void _pickCompareModule() {
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final e in installedModules.entries)
              if (e.key != _moduleId)
                ListTile(
                  dense: true,
                  leading: e.key == _compareModuleId
                      ? Icon(Icons.check, size: 18, color: p.accent)
                      : const SizedBox(width: 18),
                  title: Text(e.value),
                  onTap: () {
                    Navigator.of(context).pop();
                    _rebuild(() => _compareModuleId = e.key);
                    _load(e.key);
                    final m = _mods[e.key];
                    if (m != null) _ensureChapter(m, _code, _ch);
                    _rebuild(() => _mobilePane = 'second');
                  },
                ),
          ],
        ),
      ),
    );
  }

  /// Выбор второго перевода для сравнения — любой модуль из каталога.
  Widget _comparePicker(Palette p) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: _compareModuleId,
        isDense: true,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: p.muted,
        ),
        items: [
          for (final id in installedModules.keys)
            if (id != _moduleId)
              DropdownMenuItem(value: id, child: Text(moduleName(id))),
        ],
        onChanged: (v) {
          if (v == null) return;
          _rebuild(() => _compareModuleId = v);
          final m = _mods[v];
          if (m != null) _ensureChapter(m, _code, _ch);
          _load(v);
          // Смена состояния панели — обновляет снимок текущей записи,
          // а не стек (ADR 0019).
          workspace.updateSnapshot(_paneSnapshot());
        },
      ),
    );
  }

  /// Чипы переводов строчного сравнения (3+, ADR 0020): список
  /// модулей слоя compare в порядке показа; «+» — лист выбора.
  Widget _interleavedPicker(Palette p) {
    final ids = _compareIds;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final id in ids)
          InputChip(
            label: Text(moduleName(id), style: const TextStyle(fontSize: 12)),
            visualDensity: VisualDensity.compact,
            onDeleted: () {
              final rest = ids.where((e) => e != id).toList();
              if (rest.isEmpty) {
                // Без переводов сравнение выключено целиком.
                _rebuild(() => _interleaved = false);
                workspace.updateSnapshot(_paneSnapshot());
              } else {
                _setInterleavedModules(rest);
              }
            },
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 16),
          label: Text(
            tr('Перевод', 'Module'),
            style: const TextStyle(fontSize: 12),
          ),
          visualDensity: VisualDensity.compact,
          onPressed: _interleavedModulesSheet,
        ),
      ],
    );
  }

  /// Инициализировать список сравнения старым одиночным вторым
  /// переводом при первом включении (пустая настройка).
  void _initCompareModules() {
    if (settings.interleavedModules.isNotEmpty) {
      for (final id in settings.interleavedList) {
        _load(id);
        final m = _mods[id];
        if (m != null) _ensureChapter(m, _code, _ch);
      }
      return;
    }
    settings.update(() => settings.interleavedModules = _compareModuleId);
    final m = _mods[_compareModuleId];
    if (m != null) _ensureChapter(m, _code, _ch);
  }

  /// Записать список модулей сравнения (снимок панели + настройки).
  void _setInterleavedModules(List<String> ids) {
    settings.update(() => settings.interleavedModules = ids.join(','));
    for (final id in ids) {
      _load(id);
      final m = _mods[id];
      if (m != null) _ensureChapter(m, _code, _ch);
    }
    workspace.updateSnapshot(_paneSnapshot());
    _rebuild(() {});
  }

  /// Лист выбора переводов сравнения: чек-лист модулей, порядок —
  /// порядок включения (перестановка — после релиза).
  void _interleavedModulesSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final e in installedModules.entries)
                if (e.key != _moduleId)
                  CheckboxListTile(
                    dense: true,
                    value: _compareIds.contains(e.key),
                    title: Text(e.value),
                    onChanged: (v) {
                      final ids = _compareIds;
                      if (v == true) {
                        ids.add(e.key);
                      } else {
                        ids.remove(e.key);
                      }
                      _setInterleavedModules(ids);
                      setSheet(() {});
                    },
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _compareBody(Palette p) {
    final secondMod = _mods[_compareModuleId];
    return Container(
      width: 460,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.edge)),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: p.card,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: _comparePicker(p),
          ),
          Expanded(child: _compareColumn(secondMod, p, _compareScroll)),
        ],
      ),
    );
  }

  /// Колонка сравнения: каждый стих второго перевода — под
  /// соответствующим ему стихом основного (сопоставление через
  /// версификацию, вопрос 8). Стихи без соответствия во второй
  /// главе дописываются в конец со своими номерами.
  Widget _compareColumn(
    ModuleDoc? secondMod,
    Palette p, [
    ScrollController? controller,
  ]) {
    if (secondMod == null) {
      return Center(
        child: Text(
          tr('не выгружена', 'not available'),
          style: TextStyle(color: p.muted),
        ),
      );
    }
    _ensureConv();
    final second = secondMod.chapter(_code, _ch);
    if (second == null) {
      _ensureChapter(secondMod, _code, _ch);
      return Center(
        child: Text(
          tr('не выгружена', 'not available'),
          style: TextStyle(color: p.muted),
        ),
      );
    }
    final plainCache = <String, Map<int, String>>{
      '$_code:$_ch': _plainVerses(second),
    };
    final numStyle = TextStyle(
      fontSize: 11 * settings.fontScale,
      color: p.muted,
    );
    final textStyle = TextStyle(
      fontFamily: readingFontFamily(settings.readingFont),
      fontSize: 14 * settings.fontScale,
      color: p.ink,
      height: 1.55,
    );
    Widget row(String num, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text.rich(
        TextSpan(
          style: textStyle,
          children: [
            if (num.isNotEmpty) TextSpan(text: '$num ', style: numStyle),
            TextSpan(text: text),
          ],
        ),
      ),
    );

    final used = <String>{};
    final rows = <Widget>[];
    // Надписание (стих 0) — отдельной строкой с подписью (вопрос 9).
    final sup = _secondTexts(secondMod, plainCache, _targetsOf(0));
    final mainCh = _module?.chapter(_code, _ch);
    final mainHas0 = mainCh != null && _plainVerses(mainCh).containsKey(0);
    if (sup.isNotEmpty || mainHas0) {
      for (final t in sup) {
        used.add('${t.point.book}:${t.point.chapter}:${t.point.verse}');
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('надписание', 'superscription'),
                style: TextStyle(
                  fontSize: 10 * settings.fontScale,
                  color: p.muted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              Text(
                sup.isEmpty ? '—' : [for (final t in sup) t.text].join(' '),
                style: textStyle.copyWith(fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      );
    }
    // Стихи основного → соответствия во втором (номер префиксом,
    // при другой главе — «глава:стих»).
    if (mainCh != null) {
      final mv = _plainVerses(mainCh).keys.toList()
        ..sort()
        ..remove(0);
      for (final v in mv) {
        for (final it in _secondTexts(secondMod, plainCache, _targetsOf(v))) {
          used.add('${it.point.book}:${it.point.chapter}:${it.point.verse}');
          rows.add(
            row(
              it.point.chapter == _ch && it.point.verse == v
                  ? '${it.point.verse}'
                  : '${it.point.chapter}:${it.point.verse}',
              it.text,
            ),
          );
        }
      }
    }
    // Стихи второй главы, оставшиеся без соответствия, — в конец.
    for (final e
        in (plainCache['$_code:$_ch']!.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))) {
      if (e.key == 0) continue;
      if (used.contains('$_code:$_ch:${e.key}')) continue;
      rows.add(row('${e.key}', e.value));
    }
    if (rows.isEmpty) {
      return Center(
        child: Text(
          tr('не выгружена', 'not available'),
          style: TextStyle(color: p.muted),
        ),
      );
    }
    return _pinchZoom(
      ListView.builder(
        controller: controller,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        itemCount: rows.length,
        itemBuilder: (_, i) => rows[i],
      ),
    );
  }

  // ---------- действия по стиху ----------

  /// Плоский текст стиха (для «Копировать»/«Поделиться» и context записи).
}
