import '../l10n.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../data.dart';
import '../lexicon.dart';
import '../models.dart';
import '../native_bridge.dart' show UserEntry;
import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.html) '../native_bridge_web.dart';
import '../reader/notes_sheet.dart';
import '../reader/page_swipe.dart';
import '../reader/reader_dialogs.dart';
import '../reader/tts_service.dart';
import '../refs.dart';
import '../state.dart';
import '../vrs.dart';
import '../theme.dart';
import '../voice/voice_backend.dart' show WordMark;
import '../workspace/contributions.dart';
import '../workspace/reader_workspace.dart';
import '../workspace/workspace_model.dart';
import 'history_screen.dart';
import 'search_screen.dart';
import 'verse_compare_screen.dart';
import '../routes.dart';

part '../reader/chapter_renderer.dart';
part '../reader/reader_chrome.dart';
part '../reader/reader_controller.dart';
part '../reader/reader_pane.dart';

/// Экран чтения главы: вёрстка абзацами/построчно, свайпы через границы
/// книг, сноски, слова Иисуса, номера Стронга, сравнение переводов.
class ReadingScreen extends StatefulWidget {
  const ReadingScreen({
    super.key,
    required this.bookCode,
    required this.chapter,
    this.verse,
    this.moduleId,
  });
  final String bookCode;
  final int chapter;
  final int? verse;

  /// Стартовый перевод (наследуется у ссылающегося экрана, иначе russyn).
  final String? moduleId;

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  /// Текущая раскладка ADR 0014: одна панель чтения.
  /// Дальнейшие шаги рефакторинга передают её в ReaderPane.
  /// Имя не `workspace` — не затеняет глобальный синглтон позиций.
  final WorkspaceConfig layout = WorkspaceConfig.singleReader();

  late String _code = widget.bookCode;
  late int _ch = widget.chapter;

  final Map<String, ModuleDoc> _mods = {};
  late String _moduleId = widget.moduleId ?? mainModuleId();
  bool _compare = false;

  /// Строчное сравнение: под каждым стихом основного перевода —
  /// тот же стих второго перевода (макет будущего подстрочника).
  bool _interleaved = false;
  bool _notesOpen = false;
  int? _selectedVerse;

  /// Позиция последнего тапа по тексту — якорь всплывающего
  /// меню стиха (меню открывается рядом с местом нажатия).
  Offset _lastTapPos = Offset.zero;

  /// Нижняя панель управления: прячется при прокрутке, возвращается
  /// по тапу на тексте.
  bool _barVisible = true;

  /// Мобильный поиск: плавающее поле над нижней панелью (кнопка
  /// «Поиск» рядом с «Ещё»).
  bool _searchOpen = false;
  final _searchCtrl = TextEditingController();

  /// Фокус поля поиска: autofocus одного TextField при вставке в
  /// уже показанный экран ненадёжен — фокус просим явно после
  /// кадра (см. переключатель «Поиск»).
  final _searchFocus = FocusNode();

  /// Второй перевод в режиме сравнения.
  late String _compareModuleId = _moduleId == 'engwebp' ? 'russyn' : 'engwebp';
  final ScrollController _compareScroll = ScrollController();

  /// Кэш конверсии версификаций для текущей главы: стих основного
  /// перевода -> соответствующие координаты во втором (вопрос 8).
  /// null — одинаковые версификации или ещё не посчитано (тогда
  /// используется тот же номер — короткий путь).
  Map<int, List<CvPoint>>? _conv;

  /// Ключ кэша конверсии: 'книга:глава:основной->второй'.
  String _convKey = '';

  /// Защита от обратного вызова при синхронной прокрутке колонок.
  bool _syncingScroll = false;

  /// verse -> ключ блока, где стих начинается (для прокрутки).
  final Map<int, GlobalKey> _blockKeys = {};

  /// В ленте «книга» номера стихов повторяются между главами,
  /// поэтому ключ — «глава:стих».
  final Map<String, GlobalKey> _bookVerseKeys = {};
  final ScrollController _scroll = ScrollController();

  /// Записи к стихам текущей главы: verse -> запись.
  final Map<int, UserEntry> _highlights = {};
  final Map<int, UserEntry> _verseNotes = {};

  /// Закладки и теги стихов главы: verse -> запись.
  final Map<int, UserEntry> _verseMarks = {};
  final Map<int, UserEntry> _tagEntries = {};

  // TTS: чтение главы вслух с подсветкой читаемого стиха.
  late final ReaderTtsService _ttsService;

  bool get _ttsPlaying => _ttsService.playing;
  bool get _ttsPaused => _ttsService.paused;
  int? get _ttsVerse => _ttsService.verse;

  /// Очередь чтения: стих -> текст, и текущая позиция в ней.
  List<MapEntry<int, String>> get _ttsList => _ttsService.list;
  int get _ttsIndex => _ttsService.index;

  /// Позиция ползунка плеера во время перетаскивания (null — не тащат).
  int? _ttsDrag;

  /// Курсор пословной подсветки (ADR 0017): при построении спанов
  /// читаемого стиха считается сырой сдвиг по тексту и ведущие
  /// пробелы — смещения движка относятся к обрезанному тексту.
  /// _ttsWordCtx разрешает подсветку только в основном тексте
  /// (в колонке сравнения чужие смещения неприменимы).
  bool _ttsInVerse = false;
  bool _ttsWordCtx = false;
  int _ttsRaw = 0;
  int _ttsLead = 0;
  bool _ttsLeadDone = false;

  /// «Жидкое стекло» панелей: минимальный блюр (текст сквозь панель
  /// читается), лёгкая заливка и светлый блик по краю, обращённому
  /// к контенту, — как у Apple liquid glass.
  static const double _glassBlur = 2;
  static const double _glassAlpha = 0.3;
  static Color _glassRim(Palette p) => Colors.white.withValues(
    alpha: p.card.computeLuminance() > 0.5 ? 0.5 : 0.12,
  );

  /// Текст последнего выделения в SelectionArea — для меню действий
  /// со стихами (копируется текстом с номерами стихов).
  String? _selectedText;

  final _tapRecognizers = <TapGestureRecognizer>{};
  Map<String, LexiconEntry>? _lex;

  ModuleDoc? get _module => _mods[_moduleId];

  /// Перестроение из reader/*-частей без прямого доступа к protected setState.
  void _rebuild(VoidCallback fn) => setState(fn);

  /// Снимок состояния панели для записи стека (ADR 0019):
  /// «назад» восстанавливает строчное сравнение и его перевод.
  Map<String, Object?> _paneSnapshot() => {
    'interleaved': _interleaved,
    'cmp': _compareModuleId,
  };

  /// Применить позицию рабочего места к экрану — единый переход для
  /// свайпов, ссылок и шагов «назад/вперёд»: перевод, глава, снимок
  /// панели, прокрутка до стиха, журнал. Новых экранов не создаёт.
  void _applyLocation(Location loc, [String? banner]) {
    _stopTts();
    final cmp = loc.pane['cmp'] as String?;
    _rebuild(() {
      _moduleId = loc.moduleId;
      _code = loc.book;
      _ch = loc.chapter;
      _selectedVerse = null;
      _notesOpen = false;
      _interleaved = loc.pane['interleaved'] as bool? ?? _interleaved;
      if (cmp != null && cmp != _moduleId) _compareModuleId = cmp;
      _blockKeys.clear();
      _bookVerseKeys.clear();
    });
    _scroll.jumpTo(0);
    if (_compareScroll.hasClients) _compareScroll.jumpTo(0);
    _load(_moduleId);
    _loadVerseEntries();
    progress.markRead(loc.book, loc.chapter);
    progress.setPosition(loc.book, loc.chapter);
    history.touch(loc.moduleId, loc.book, loc.chapter, verse: loc.verse);
    // Главы соседних экранов .sb подгружаем по месту.
    for (final m in _mods.values) {
      _ensureChapter(m, loc.book, loc.chapter);
    }
    // Восстановление — до стиха, не до пикселя (ADR 0019).
    final target = loc.verse > 0
        ? loc.verse
        : progress.lastVerse['${loc.book}:${loc.chapter}'];
    _scrollToVerse(target);
    if (banner != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(banner),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _ttsService = ReaderTtsService(
      isActive: () => mounted,
      onChanged: () {
        if (mounted) setState(() {});
      },
      onVerse: _scrollToVerse,
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      },
      titleOf: () => '${_titleOf(_code)} $_ch',
    );
    // Грузим только нужные модули: текущий + перевод сравнения.
    // Загрузка всех модулей сразу (а с большими .sb вроде -ru
    // и comm-henry это сотни МБ JSON) давала пик памяти при каждом
    // переходе на экран чтения — Android убивал процесс
    // (симптом: белый экран и вылет на рабочий стол).
    _load(_moduleId);
    if (_compareModuleId != _moduleId) _load(_compareModuleId);
    _loadVerseEntries();
    history.touch(_moduleId, _code, _ch, verse: widget.verse ?? 0);
    // Входная позиция рабочего места (ADR 0019): стек единый,
    // внутренние переходы не создают новых экранов.
    workspace.go(
      Location.verse(
        moduleId: _moduleId,
        book: _code,
        chapter: _ch,
        verse: widget.verse ?? 0,
        pane: _paneSnapshot(),
      ),
    );
    // Синхронная прокрутка: основная колонка ведёт колонку сравнения и обратно.
    _scroll.addListener(() => _syncScroll(_scroll, _compareScroll));
    _compareScroll.addListener(() => _syncScroll(_compareScroll, _scroll));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      progress.markRead(_code, _ch);
      progress.setPosition(_code, _ch);
      // Явно заданный стих или последний открытый — к нему и прокручиваем.
      _scrollToVerse(widget.verse ?? progress.lastVerse['$_code:$_ch']);
    });
  }

  @override
  void dispose() {
    for (final r in _tapRecognizers) {
      r.dispose();
    }
    _tapRecognizers.clear();
    _ttsService.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    _compareScroll.dispose();
    super.dispose();
  }

  /// Поиск стиха в ленте книги уже идёт (ленивый ListView).
  bool _seeking = false;

  /// Pinch-zoom основного текста (fontScale): отслеживаемые пальцы,
  /// дистанция и масштаб на старте щипка; _pinching — жест двумя
  /// пальцами реально начался (сохранять настройку по концу).
  final Map<int, Offset> _pinchPtrs = {};
  double _pinchDist0 = 0;
  double _pinchFont = 1.0;
  bool _pinching = false;

  /// Входящая страница листания: целевая глава без прокрутки и без
  /// якорей (peek — превью, ключи нужны только живой странице).
  Widget _peekPage(Palette p, bool wide, String code, int chapter) {
    final doc = _module?.chapter(code, chapter);
    final maxW = settings.columnWidth == ColumnWidth.reading && wide
        ? 720.0
        : double.infinity;
    Widget inner;
    if (doc == null) {
      inner = Padding(
        padding: const EdgeInsets.only(top: 160),
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2, color: p.muted),
          ),
        ),
      );
    } else {
      inner = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Text(
              '${_titleOf(code)} · '
              '${tr('Глава $chapter', 'Chapter $chapter')}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: readingFontFamily(settings.readingFont),
                fontSize: 19 * settings.fontScale,
                fontWeight: FontWeight.w800,
                color: _verseColor(p),
              ),
            ),
          ),
          ...(settings.layoutMode == LayoutMode.book
              ? _bookBlocks(doc, p, chapter, true)
              : _buildChapter(doc, p, true)),
        ],
      );
    }
    return Container(
      color: p.background,
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          wide ? 48 : 20,
          _topClear(),
          wide ? 48 : 20,
          wide ? 20 : _bottomClear(),
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: inner,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = MediaQuery.of(context).size.width >= 700;
    final group = kBookGroup[_code] ?? BookGroup.torah;
    final color = groupColor(group, appThemeOf(context));
    final ch = _module?.chapter(_code, _ch);
    final notes = ch == null
        ? <({int verse, NoteSpanDoc note})>[]
        : _notesOf(ch);

    return CallbackShortcuts(
      // ← → на клавиатуре листают главы (как свайпы на телефоне).
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
      },
      child: Focus(
        autofocus: true,
        // Системный «назад» — сначала шаг по стеку рабочего места;
        // стек пуст — обычный pop (на «Домой»/к открывшему экрану).
        // Открытые листы/меню закрывает само дерево виджетов раньше.
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // Порядок закрытия (ADR 0019): шторки/меню закрывает
            // дерево само; поле поиска — следующим; затем стек.
            if (_searchOpen) {
              setState(() => _searchOpen = false);
              return;
            }
            final loc = workspace.back();
            if (loc != null) {
              _applyLocation(loc);
            } else {
              Navigator.of(context).pop();
            }
          },
          child: Scaffold(
          body: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                // Прокрутка текста прячет панель управления.
                onNotification: (n) {
                  if (n is ScrollUpdateNotification && _barVisible) {
                    setState(() => _barVisible = false);
                  }
                  return false;
                },
                child: ReaderPageSwipe<(String, int, String?)>(
                  targetFor: _goTarget,
                  prepareTarget: (t) {
                    final m = _module;
                    if (m != null) _ensureChapter(m, t.$1, t.$2);
                  },
                  peekBuilder: (t) => _peekPage(p, wide, t.$1, t.$2),
                  canStart: () =>
                      _selectedText == null || _selectedText!.isEmpty,
                  onTap: () {
                    if (!_barVisible) setState(() => _barVisible = true);
                  },
                  onCommit: _go,
                  child: Row(
                    children: [
                      Expanded(
                        child: Directionality(
                          textDirection: _isRtl
                              ? TextDirection.rtl
                              : TextDirection.ltr,
                          child: _readingBody(ch, p, wide),
                        ),
                      ),
                      if (_compare && wide && !_interleaved) _compareBody(p),
                      if (_notesOpen && wide)
                        Container(
                          width: 360,
                          decoration: BoxDecoration(
                            border: Border(left: BorderSide(color: p.edge)),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Text(
                                      tr(
                                        'Сноски и параллельные',
                                        'Footnotes and cross-refs',
                                      ),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: p.ink,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: tr('Закрыть', 'Close'),
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () =>
                                        setState(() => _notesOpen = false),
                                  ),
                                ],
                              ),
                              Expanded(
                                child: NotesSheet(
                                  notes: notes,
                                  selectedVerse: _selectedVerse,
                                  controller: ScrollController(),
                                  onRef: _goToRef,
                                  variants: ch?.variants ?? const [],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Верхняя панель: назад + «Книга Гл.» + поле поиска.
              // На десктопе она же несёт все кнопки управления; на
              // телефоне кнопки живут в нижней панели.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: AnimatedSlide(
                  offset: _barVisible ? Offset.zero : const Offset(0, -1),
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: _barVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 250),
                    child: _topBar(p, color, wide: wide),
                  ),
                ),
              ),
              // Нижняя панель кнопок — только на узком экране.
              if (!wide)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedSlide(
                    offset: _barVisible ? Offset.zero : const Offset(0, 1),
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    child: AnimatedOpacity(
                      opacity: _barVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 250),
                      child: _controlBar(p, color, wide: wide),
                    ),
                  ),
                ),
              // Плавающее поле поиска — над нижней панелью, не
              // закрывает текст (мобильная раскладка).
              if (!wide && _searchOpen) _searchField(p),
              // Мини-плеер чтения вслух: пауза/перемотка по стихам,
              // плавает над нижней панелью и остаётся, когда панели
              // спрятаны прокруткой.
              if (_ttsPlaying)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  left: 12,
                  right: 12,
                  bottom: (_barVisible && !wide)
                      ? MediaQuery.of(context).padding.bottom + 64
                      : MediaQuery.of(context).padding.bottom + 12,
                  child: _ttsPlayer(p),
                ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  String _mobilePane = 'main';
}
