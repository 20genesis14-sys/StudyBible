part of '../screens/reading_screen.dart';

/// Одна панель чтения и сравнение переводов.
extension _ReaderPane on _ReadingScreenState {
  Widget _readingBody(ChapterDoc? ch, Palette p, bool wide) {
    final maxW = settings.columnWidth == ColumnWidth.reading && wide
        ? 720.0
        : double.infinity;
    Widget content;
    if (settings.layoutMode == LayoutMode.book && !_interleaved && !_compare) {
      // «Бесконечная книга»: вся книга одной лентой.
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
        child: SingleChildScrollView(
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
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: SelectionArea(
                onSelectionChanged: (c) => _selectedText = c?.plainText,
                contextMenuBuilder: _selectionMenu,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _interleaved
                      ? _buildInterleaved(ch, p)
                      : _buildChapter(ch, p),
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
      final second = _mods[_compareModuleId]?.chapter(_code, _ch);
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
                ? _simpleChapter(second, p)
                : content,
          ),
        ],
      );
    }
    return content;
  }

  String _shortModuleName(String id) {
    final n = kModules[id] ?? id;
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
            for (final e in kModules.entries)
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
          for (final id in kModules.keys)
            if (id != _moduleId)
              DropdownMenuItem(value: id, child: Text(kModules[id] ?? id)),
        ],
        onChanged: (v) {
          if (v == null) return;
          _rebuild(() => _compareModuleId = v);
          final m = _mods[v];
          if (m != null) _ensureChapter(m, _code, _ch);
          _load(v);
        },
      ),
    );
  }

  Widget _compareBody(Palette p) {
    final ch = _mods[_compareModuleId]?.chapter(_code, _ch);
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
          Expanded(child: _simpleChapter(ch, p, _compareScroll)),
        ],
      ),
    );
  }

  /// Упрощённый текст для второй панели (без интерактива).
  Widget _simpleChapter(
    ChapterDoc? ch,
    Palette p, [
    ScrollController? controller,
  ]) {
    if (ch == null) {
      return Center(
        child: Text(
          tr('не выгружена', 'not available'),
          style: TextStyle(color: p.muted),
        ),
      );
    }
    return ListView(
      controller: controller,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        for (final b in ch.blocks)
          if (b.kind == BlockKind.heading)
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(
                _plainText(b),
                style: TextStyle(
                  fontFamily: readingFontFamily(settings.readingFont),
                  fontWeight: FontWeight.w700,
                  fontSize: 13 * settings.fontScale,
                  color: p.ink,
                ),
              ),
            )
          else if (b.kind != BlockKind.blank)
            Padding(
              padding: EdgeInsets.only(
                bottom: 8,
                left: b.kind == BlockKind.poetry ? 20 : 0,
              ),
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontFamily: readingFontFamily(settings.readingFont),
                    fontSize: 14 * settings.fontScale,
                    color: p.ink,
                    height: 1.55,
                  ),
                  children: [
                    for (final s in b.spans)
                      if (s is VerseSpanDoc)
                        TextSpan(
                          text: '${s.verse} ',
                          style: TextStyle(
                            fontSize: 11 * settings.fontScale,
                            color: p.muted,
                          ),
                        )
                      else if (s is TextSpanDoc)
                        TextSpan(
                          text: s.text,
                          style: TextStyle(
                            color: s.style == 'wj' ? p.jesus : p.ink,
                          ),
                        ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  // ---------- действия по стиху ----------

  /// Плоский текст стиха (для «Копировать»/«Поделиться» и context записи).
}
