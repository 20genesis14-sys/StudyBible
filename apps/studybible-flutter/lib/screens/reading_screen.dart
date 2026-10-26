import '../l10n.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../data.dart';
import '../error_log.dart';
import '../lexicon.dart';
import '../models.dart';
import '../frag.dart';
import '../native_bridge.dart' show UserEntry;
import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.js_interop) '../native_bridge_web.dart';
import '../reader/line_cache.dart';
import '../reader/notes_sheet.dart';
import '../reader/page_swipe.dart';
import '../reader/reader_dialogs.dart';
import '../reader/tts_service.dart';
import '../refs.dart';
import '../state.dart';
import '../vrs.dart';
import '../theme.dart';
import '../userdata_bus.dart';
import '../voice/voice_backend.dart' show WordMark;
import '../workspace/contributions.dart';
import '../workspace/reader_workspace.dart';
import '../workspace/workspace_model.dart';
import '../workspace/workspace_presets.dart';
import 'chapter_grid_screen.dart';
import 'history_screen.dart';
import '../routes.dart';
import 'search_screen.dart';
import 'verse_compare_screen.dart';

part '../reader/chapter_renderer.dart';
part '../reader/pane_controller.dart';
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
    this.openedFromGrid = false,
  });
  final String bookCode;
  final int chapter;
  final int? verse;

  /// Открыта из сетки глав: «назад» шапки может просто pop'нуться на
  /// неё (иначе — pushReplacement на ChapterGridScreen, см. шапку).
  final bool openedFromGrid;

  /// Стартовый перевод (наследуется у ссылающегося экрана, иначе russyn).
  final String? moduleId;

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  /// Контроллеры панелей чтения (B10 этап 2): список из одной панели —
  /// прежнее поведение экрана; две — режим «две панели». Панечно-
  /// волатильное состояние — в контроллере (B10 этап 1, ADR 0014);
  /// экран владеет TTS, хромом на нотифаерах и стеком рабочего места.
  final List<ReaderPaneController> panes = [];

  /// Активная панель: с ней работают хром, клавиши, запись прогресса
  /// и журнала (B10 этап 2). Тап в панели переводит фокус на неё.
  int activePane = 0;

  /// Панель — владелец очереди чтения вслух (B10 этап 2): очередь
  /// принадлежит панели, где её запустили; смена фокуса её не двигает
  /// и не глушит.
  int ttsOwnerPane = 0;

  /// Активная панель — цель хрома и клавиатуры: все прежние чтения
  /// `pane.` в хроме/построении остались осмысленными (B10 этап 2).
  ReaderPaneController get pane => panes[activePane];

  // TTS: чтение главы вслух с подсветкой читаемого стиха.
  late final ReaderTtsService _ttsService;

  /// Отложенное возобновление чтения вслух после перехода
  /// (книга, глава, стих). Ставится в [_applyLocationFor], когда
  /// чтение шло; потребляется в [ReaderPaneController._load]/
  /// [ReaderPaneController._ensureChapter], когда глава догрузилась.
  /// null — возобновления нет.
  ({String book, int chapter, int verse})? _ttsResumeChapter;

  bool get _ttsPlaying => _ttsService.playing;
  bool get _ttsPaused => _ttsService.paused;
  int? get _ttsVerse => _ttsService.verse;

  /// Очередь чтения: стих -> текст, и текущая позиция в ней.
  List<MapEntry<int, String>> get _ttsList => _ttsService.list;
  int get _ttsIndex => _ttsService.index;

  /// Позиция ползунка плеера во время перетаскивания (null — не тащат).
  /// Нотифаер: на каждый шаг драга перестраивается только мини-плеер,
  /// не весь экран (ADR 0030).
  final ValueNotifier<int?> _ttsDragN = ValueNotifier(null);

  /// «Жидкое стекло» панелей: минимальный блюр (текст сквозь панель
  /// читается), лёгкая заливка и светлый блик по краю, обращённому
  /// к контенту, — как у Apple liquid glass.
  static const double _glassBlur = 2;
  static const double _glassAlpha = 0.3;
  static Color _glassRim(Palette p) => Colors.white.withValues(
    alpha: p.card.computeLuminance() > 0.5 ? 0.5 : 0.12,
  );

  final _searchCtrl = TextEditingController();

  /// Фокус поля поиска: autofocus одного TextField при вставке в
  /// уже показанный экран ненадёжен — фокус просим явно после
  /// кадра (см. переключатель «Поиск»).
  final _searchFocus = FocusNode();

  // ---------- хром на нотифаерах (ADR 0030) ----------

  /// Видимость верхней/нижней панелей и плавающих кнопок.
  final ValueNotifier<bool> _barVisN = ValueNotifier(true);

  /// Плавающее поле поиска (мобильная раскладка).
  final ValueNotifier<bool> _searchOpenN = ValueNotifier(false);

  /// Боковая панель сносок (десктоп).
  final ValueNotifier<bool> _notesOpenN = ValueNotifier(false);

  /// Текущее слово чтения вслух: тик слова перестраивает только
  /// активную строку, слушающую этот нотифаер (ADR 0030).
  final ValueNotifier<WordMark?> _ttsWordN = ValueNotifier(null);

  /// Контроллер скролла десктопной панели сносок — поле состояния:
  /// создание в build() сбрасывало позицию и текло (BUGS 18.10.2026).
  final ScrollController _notesCtrl = ScrollController();

  /// Доступ к хрому через нотифаеры (ADR 0030): запись вне build
  /// меняет только слушающий хром, текст не трогает.
  bool get _barVisible => _barVisN.value;
  set _barVisible(bool v) => _barVisN.value = v;
  bool get _searchOpen => _searchOpenN.value;
  bool get _notesOpen => _notesOpenN.value;
  set _notesOpen(bool v) => _notesOpenN.value = v;

  /// Отложенная перечитка главы по шине записей пользователя: не
  /// более одной на кадр, сколько бы мутаций ни пришло (B8).
  bool _userDataReloadQueued = false;

  /// Идёт взаимная синхронизация панелей (B10 этап 2): применённая
  /// позиция не порождает ответной синхронизации.
  bool _syncing = false;

  /// Проводка скролла между связанными панелями (B10 этап 2):
  /// прокрутка одной панели пропорционально ведёт вторую — как
  /// колонка сравнения. [_crossSyncing] гасит обратную волну и
  /// программные прыжки (applySyncedVerse).
  bool _crossSyncing = false;

  // ---------- рабочее место между запусками (B10 этап 2) ----------

  /// Восстановленный снимок рабочего места (decodeWorkspace от
  /// Settings.workspaceJson): панель 0 создаётся из него в initState,
  /// вторая панель — в [didChangeDependencies] на широком экране.
  /// null — прежнее поведение (одна панель от аргументов).
  WorkspaceConfig? _savedWs;

  /// Восстановление снимка выполнено один раз (didChangeDependencies
  /// вызывается и на смены MediaQuery).
  bool _wsRestored = false;

  /// Последний применённый пресет раскладки (B10 этап 2): идёт в
  /// снимок позиции стека ('preset') и в workspaceJson (options
  /// панели 0). null — пресет не выбран (ручная раскладка).
  String? _activePresetId;

  /// Пользователь тащил границу панелей сам — пресеты больше не
  /// сбрасывают [splitRatio] к 0.5.
  bool _ratioTouched = false;

  /// Отложенная запись рабочего места (B10 этап 2): таймер дебаунса
  /// (800 мс) и признак незакрытой записи (дописывается в dispose).
  Timer? _wsSaveTimer;
  bool _wsSavePending = false;

  /// Отношение сторон панелей (B10 этап 2): доля ширины левой панели,
  /// 0.25–0.75; тянется за границей. Едет в снимке позиции ('ratio').
  double splitRatio = 0.5;

  /// Извещение шины записей пользователя (B8): перечитать главы
  /// панелей, когда область мутации совпадает с ними — или область
  /// не указана. Раздача на все панели (B10 этап 2); события
  /// коалицируются: на кадр не больше одной перечитки. Начальные
  /// загрузки (initState, _applyLocationFor) и смены контекста
  /// (перевод, глава) шину не проходят.
  void _onUserDataChanged() {
    final scope = userDataBus.lastScope;
    if (_userDataReloadQueued) return;
    _userDataReloadQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _userDataReloadQueued = false;
      if (!mounted) return;
      for (final p in panes) {
        if (scope == null ||
            (scope.module == p._moduleId &&
                scope.book == p._code &&
                scope.chapter == p._ch)) {
          p._loadVerseEntries();
        }
      }
    });
  }

  /// Фабрика панелей (B10 этап 2): хуки замыкаются на индекс —
  /// переходы применяются к своей панели ([_applyLocationFor]), тап
  /// по стиху фокусирует свою, [onSelectVerse]/[onOpenNotes] ведут
  /// хром к своей панели. Остальное — экранное (TTS, стек, поиск).
  ReaderPaneController _makePane({
    required int index,
    String? bookCode,
    int? chapter,
    String? moduleId,
    int? verse,
  }) {
    return ReaderPaneController(
      index: index,
      isAlive: () => mounted,
      initialVerse: verse,
      bookCode: bookCode ?? widget.bookCode,
      chapter: chapter ?? widget.chapter,
      moduleId: moduleId ?? widget.moduleId,
      applyLocation: (loc, [banner]) => _applyLocationFor(index, loc, banner),
      openScreen: _openScreen,
      // TTS-хуки отвечают только панели-владельцу очереди (B10
      // этап 2): чужая панель видит «чтения нет» — подсветки и
      // возобновления в ней не будет.
      ttsVerseOf: () => ttsOwnerPane == index ? _ttsService.verse : null,
      ttsWordOf: () => ttsOwnerPane == index ? _ttsService.word : null,
      ttsWordN: _ttsWordN,
      cancelTtsResume: () {
        if (ttsOwnerPane == index) _ttsResumeChapter = null;
      },
      resumeTtsAfterNavigation: ([doc]) {
        if (ttsOwnerPane == index) _ttsResumeAfterNavigation(doc);
      },
      onSelectVerse: (v, [chCtx]) {
        _setActivePane(index);
        _selectVerse(v, chCtx);
      },
      onOpenNotes: () {
        _setActivePane(index);
        _openNotes();
      },
      snapshotExtra: () => _splitSnapshotExtra(index),
    );
  }

  /// Режим «две панели» — длина списка (B10 этап 2).
  bool get _split => panes.length > 1;

  /// Экранная часть снимка позиции (B10 этап 2): режим «две панели»,
  /// отношение сторон, позиция пассивной панели и последний пресет
  /// ('preset'). В одной панели надстройка пуста (кроме пресета) —
  /// снимки стека остаются прежними.
  Map<String, Object?> _splitSnapshotExtra(int index) {
    final preset = _activePresetId;
    if (!_split) {
      return preset == null ? const {} : {'preset': preset};
    }
    final other = panes[index == 0 ? 1 : 0];
    return {
      'split': true,
      'ratio': splitRatio,
      // Владелец записи: «назад/вперёд» применяют запись своей
      // панели, а не фокусной (ревью B10-2, находка 1).
      'paneIdx': index,
      'preset': ?preset,
      'other': {
        'module': other._moduleId,
        'book': other._code,
        'ch': other._ch,
        'v': other._selectedVerse ?? 0,
      },
    };
  }

  /// Открыть вторую панель: по умолчанию — с позиции первой; из
  /// снимка позиции стека ([_restoreSplit]) или пресета/восстановления
  /// рабочего места — с указанной.
  void _openSplit({
    String? bookCode,
    int? chapter,
    String? moduleId,
    int? verse,
  }) {
    final p0 = panes[0];
    final p1 = _makePane(
      index: 1,
      bookCode: bookCode ?? p0._code,
      chapter: chapter ?? p0._ch,
      moduleId: moduleId ?? p0._moduleId,
      verse: verse,
    );
    panes.add(p1);
    // Скролл второй панели ведёт первую (обратное направление пары).
    p1._scroll.addListener(() => _crossScrollSync(1, 0));
    p1._load(p1._moduleId);
    p1._loadVerseEntries();
    // Синхронная прокрутка колонок сравнения — как у первой панели
    // (см. initState).
    p1._scroll.addListener(() => p1._syncScroll(p1._scroll, p1._compareScroll));
    p1._compareScroll.addListener(
      () => p1._syncScroll(p1._compareScroll, p1._scroll),
    );
  }

  /// Закрыть вторую панель: контроллер disposable только после кадра —
  /// ListenableBuilder снимает подписку при пересборке, removeListener
  /// у уже закрытого нотифаера уронил бы сборку. Очередь чтения вслух
  /// закрытой панели гасим: перенацелка владельца врала бы заголовком
  /// и подсветкой стиха (ревью B10-2, находка 5).
  void _closeSplit() {
    final second = panes.removeAt(1);
    if (ttsOwnerPane > 0) _stopTts();
    if (activePane > 0) activePane = 0;
    if (ttsOwnerPane > 0) ttsOwnerPane = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => second.dispose());
  }

  /// Кнопка «Две панели»: развернуть/свернуть вторую панель. Вторая
  /// стартует с позиции первой (или из снимка стека — _restoreSplit).
  /// Ручное переключение — не пресет: выбор раскладки сбрасывается.
  void _toggleSplit() {
    setState(() {
      _activePresetId = null;
      if (_split) {
        _closeSplit();
      } else {
        _openSplit();
      }
    });
    _scheduleWorkspaceSave();
  }

  /// Применить пресет раскладки (B10 этап 2):
  /// - «Чтение» — закрыть сплит, одна панель на текущей позиции;
  /// - «Сравнение» — две панели, обе привязаны ('main'); вторая —
  ///   второй перевод машины сравнения панели 0 (плейсхолдер пресета
  ///   'russyn', если сравнивать не с чем);
  /// - «Места» — две панели, обе отвязаны (''), вторая — та же книга,
  ///   глава 1, стих 1.
  /// Отношение сторон сбрасывается к 0.5, если пользователь не тащил
  /// границу сам ([_ratioTouched]).
  void _applyPreset(String id) {
    // ADR 0014: телефон — одна панель. Двухпанельные пресеты на узком
    // экране не открывают split — подсказка, раскладка не меняется.
    final wide = MediaQuery.of(context).size.width >= 700;
    if (!wide && id != 'reading') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Две панели — на широком экране',
              'Two panes need a wide screen',
            ),
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    // «Сравнение» без второго перевода — подсказка вместо пустой
    // панели (ревью B10-2, находка 9): фолбэк — любой установленный
    // перевод кроме основного.
    final p0 = panes[0];
    final second = id == 'comparing'
        ? (p0._compareModuleIdOrNull ??
              installedModules.keys.firstWhere(
                (id2) => id2 != p0._moduleId,
                orElse: () => '',
              ))
        : '';
    if (id == 'comparing' && second.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Нет второго перевода для сравнения',
              'No second translation to compare',
            ),
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() {
      _activePresetId = id;
      switch (id) {
        case 'comparing':
          _crossSyncing = true;
          if (_split) {
            panes[0].linkGroup = 'main';
            panes[1].linkGroup = 'main';
            panes[1].applySyncedVerse(second, p0._code, p0._ch, 0);
          } else {
            _openSplit(moduleId: second);
            panes[0].linkGroup = 'main';
            panes[1].linkGroup = 'main';
          }
          _crossSyncing = false;
        case 'places':
          final p0 = panes[0];
          _crossSyncing = true;
          if (!_split) _openSplit();
          panes[0].linkGroup = '';
          panes[1].linkGroup = '';
          panes[1].applySyncedVerse(p0._moduleId, p0._code, 1, 1);
          _crossSyncing = false;
        default:
          // «Чтение» и любой неизвестный пресет — одна панель.
          if (_split) _closeSplit();
          panes[0].linkGroup = 'main';
      }
      if (!_ratioTouched) splitRatio = 0.5;
    });
    _scheduleWorkspaceSave();
  }

  // ---------- запись рабочего места (B10 этап 2) ----------

  /// Текущая раскладка как конфиг модели (ADR 0014): раскладка,
  /// панели с позициями/переводами/группами связи, активная панель.
  /// Идентификатор пресета едет в options панели 0 — модель не меняется.
  WorkspaceConfig _workspaceFromState() {
    final panesCfg = <PaneConfig>[];
    for (var i = 0; i < panes.length; i++) {
      final c = panes[i];
      panesCfg.add(
        PaneConfig(
          id: i == 0 ? 'reader' : 'pane-$i',
          type: PaneType.reader,
          source: c._moduleId,
          linkGroup: c.linkGroup.isEmpty ? null : c.linkGroup,
          book: c._code,
          chapter: c._ch,
          verse: c._selectedVerse ?? 0,
          options: (i == 0 && _activePresetId != null)
              ? {'preset': _activePresetId!}
              : const {},
        ),
      );
    }
    return WorkspaceConfig(
      layout: _split
          ? WorkspaceLayoutSpec.splitHorizontal(ratio: splitRatio)
          : const WorkspaceLayoutSpec.single(),
      activePane: activePane.clamp(0, panes.length - 1),
      panes: panesCfg,
    );
  }

  /// Отложить запись рабочего места на 800 мс: осмысленные изменения
  /// (сплит, конец драга границы, пресет, переход по позиции, связь
  /// панелей) коалицируются в одну запись настроек.
  void _scheduleWorkspaceSave() {
    _wsSavePending = true;
    _wsSaveTimer?.cancel();
    _wsSaveTimer = Timer(
      const Duration(milliseconds: 800),
      _flushWorkspaceSave,
    );
  }

  /// Записать рабочее место в настройки: конфиг из живого состояния —
  /// в JSON-канал Settings.workspaceJson (запись/загрузку ведёт
  /// Settings, содержимое он не разбирает).
  void _flushWorkspaceSave() {
    _wsSaveTimer = null;
    if (!_wsSavePending || panes.isEmpty) return;
    _wsSavePending = false;
    final json = encodeWorkspace(_workspaceFromState());
    if (json == null) return;
    settings.update(() => settings.workspaceJson = json);
  }

  /// Шаг стека позиций — тоже изменение рабочего места: запись
  /// откладывается (панель ушла на новую позицию).
  void _onWorkspaceChanged() => _scheduleWorkspaceSave();

  /// Кнопка связи в шапке панели (B10 этап 2): переключает группу
  /// панели [index] между 'main' (связанная — ходит за навигацией
  /// других панелей группы) и '' (отвязанная — живёт своей позицией).
  /// Заменяет прежнее долгое нажатие кнопки «Две панели».
  void _togglePaneLink(int index) {
    if (!_split) return;
    setState(() {
      final p = panes[index];
      p.linkGroup = p.linkGroup.isEmpty ? 'main' : '';
    });
    _scheduleWorkspaceSave();
  }

  /// Восстановить режим «две панели» из снимка позиции (B10 этап 2):
  /// кнопка, отношение сторон и позиция пассивной панели едут в
  /// снимке. Отсутствие ключа 'split' раскладку не меняет — старые
  /// записи стека поверх открытого сплита его не закрывают.
  void _restoreSplit(Location loc) {
    if (loc.pane['split'] != true || _split) return;
    var book = panes[0]._code;
    var ch = panes[0]._ch;
    var mod = panes[0]._moduleId;
    final other = loc.pane['other'];
    if (other is Map) {
      mod = other['module'] as String? ?? mod;
      book = other['book'] as String? ?? book;
      ch = other['ch'] as int? ?? ch;
    }
    final ratio = loc.pane['ratio'];
    if (ratio is num) splitRatio = ratio.toDouble().clamp(0.25, 0.75);
    _openSplit(bookCode: book, chapter: ch, moduleId: mod);
  }

  /// Тап в панели переводит фокус на неё (B10 этап 2): хром, клавиши
  /// и запись прогресса работают с активной панелью. В одной панели —
  /// нет операции.
  void _setActivePane(int i) {
    if (panes.length < 2 || activePane == i) return;
    setState(() => activePane = i);
  }

  @override
  void initState() {
    super.initState();
    // Шина записей пользователя (B8): мутации извещают — экран
    // перечитывает главу сам, без ручных перечиток у мест мутаций.
    userDataBus.addListener(_onUserDataChanged);
    // Рабочее место между запусками (B10 этап 2): раскладка из
    // настроек. Битый снимок или неустановленный перевод панели 0 —
    // прежнее поведение (одна панель от аргументов виджета).
    final saved = decodeWorkspace(settings.workspaceJson);
    // Проверяем только то, что восстановление реально потребляет
    // (ревью B10-2, находка 6): позиция панели 0 не используется
    // (аргументы перехода), а вот перевод второй панели обязан быть
    // установлен.
    if (saved != null &&
        saved.panes.isNotEmpty &&
        (saved.panes.length < 2 ||
            installedModules.containsKey(saved.panes[1].source))) {
      _savedWs = saved;
    }
    final ws0 = _savedWs?.panes.first;
    // Панель 0: хуки экранного уровня — TTS-сервис, стек рабочего
    // места и хром остаются на экране (B10 этап 1); переходы и тапы
    // замыкаются на индекс панели (B10 этап 2). Позиция панели 0 —
    // всегда от аргументов перехода (дом, закладка, ссылка — намерение
    // пользователя сейчас); снимок восстанавливает раскладку, связь
    // и вторую панель, но не перебивает явный переход.
    panes.add(
      _makePane(
        index: 0,
        bookCode: widget.bookCode,
        chapter: widget.chapter,
        moduleId: widget.moduleId,
        verse: widget.verse,
      ),
    );
    if (ws0 != null) {
      panes[0].linkGroup = ws0.linkGroup ?? '';
      _activePresetId = ws0.options['preset'] as String?;
      if (_savedWs!.layout.type == WorkspaceLayoutType.splitHorizontal) {
        splitRatio = _savedWs!.layout.ratio.clamp(0.25, 0.75).toDouble();
      }
    }
    // Проводка скролла панели 0 ко второй (работает только при
    // открытом split и связи «main» — проверяет сам обработчик).
    panes[0]._scroll.addListener(() => _crossScrollSync(0, 1));
    // Запись рабочего места: шаги стека и переходы коалицируются
    // в отложенную запись настроек (B10 этап 2).
    workspace.addListener(_onWorkspaceChanged);
    _ttsService = ReaderTtsService(
      isActive: () => mounted,
      onChanged: () {
        if (mounted) setState(() {});
      },
      // Тик слова обновляет только активную строку через нотифаер
      // (ADR 0030); тик стиха остаётся на экране — с кэшем строк он
      // дёшев (перестраиваются одна-две строки).
      onWordChanged: () => _ttsWordN.value = _ttsService.word,
      // Прокрутка читаемого стиха — в панели-владельце очереди
      // (B10 этап 2), где бы ни был фокус.
      onVerse: (v) => panes[ttsOwnerPane]._scrollToVerse(v),
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      },
      titleOf: () {
        final o = panes[ttsOwnerPane];
        return '${o._titleOf(o._code)} ${o._ch}';
      },
    );
    // Грузим только нужные модули: текущий + перевод сравнения.
    // Загрузка всех модулей сразу (а с большими .sb
    // это сотни МБ JSON) давала пик памяти при каждом
    // переходе на экран чтения — Android убивал процесс
    // (симптом: белый экран и вылет на рабочий стол).
    pane._load(pane._moduleId);
    if (pane._compareModuleId != pane._moduleId) {
      pane._load(pane._compareModuleId);
    }
    pane._loadVerseEntries();
    // Позиция панели 0 — от аргументов; стих ссылки приоритетен.
    final bootVerse = widget.verse ?? 0;
    history.touch(pane._moduleId, pane._code, pane._ch, verse: bootVerse);
    // Входная позиция рабочего места (ADR 0019): стек единый,
    // внутренние переходы не создают новых экранов.
    workspace.go(
      Location.verse(
        moduleId: pane._moduleId,
        book: pane._code,
        chapter: pane._ch,
        verse: bootVerse,
        pane: pane._paneSnapshot(),
      ),
    );
    // Синхронная прокрутка: основная колонка ведёт колонку сравнения и обратно.
    pane._scroll.addListener(
      () => pane._syncScroll(pane._scroll, pane._compareScroll),
    );
    pane._compareScroll.addListener(
      () => pane._syncScroll(pane._compareScroll, pane._scroll),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      progress.markRead(pane._code, pane._ch);
      progress.setPosition(pane._code, pane._ch);
      // Явно заданный стих или последний открытый — к нему и
      // прокручиваем. Восстановленной второй панели стих задаёт
      // initialVerse (её прокрутка — в _load).
      pane._scrollToVerse(
        widget.verse ?? progress.lastVerse['${pane._code}:${pane._ch}'],
      );
    });
  }

  /// Вторая панель восстановленного рабочего места (B10 этап 2):
  /// открывается после первого кадра раскладки — ширина экрана известна
  /// только через MediaQuery, в initState его читать нельзя. Узкий экран
  /// остаётся одной панелью (ADR 0014) — позиция панели 0 уже
  /// восстановлена в initState.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wsRestored) return;
    _wsRestored = true;
    final saved = _savedWs;
    if (saved == null || saved.panes.length < 2) return;
    if (MediaQuery.of(context).size.width < 700) return;
    final s1 = saved.panes[1];
    if (!installedModules.containsKey(s1.source)) return;
    _openSplit(
      bookCode: s1.book,
      chapter: s1.chapter,
      moduleId: s1.source,
      verse: s1.verse > 0 ? s1.verse : null,
    );
    panes[1].linkGroup = s1.linkGroup ?? '';
    activePane = saved.activePane.clamp(0, panes.length - 1);
  }

  @override
  void dispose() {
    userDataBus.removeListener(_onUserDataChanged);
    workspace.removeListener(_onWorkspaceChanged);
    // Незакрытую отложенную запись рабочего места дописываем сразу —
    // контроллеры панелей ещё живы (B10 этап 2).
    _wsSaveTimer?.cancel();
    _flushWorkspaceSave();
    // Кэши рендера, распознаватели и скролл-контроллеры —
    // панечно-волатильные, их закрывает контроллер (B10 этап 1).
    for (final p in panes) {
      p.dispose();
    }
    panes.clear();
    _barVisN.dispose();
    _searchOpenN.dispose();
    _notesOpenN.dispose();
    _ttsWordN.dispose();
    _ttsDragN.dispose();
    _notesCtrl.dispose();
    _ttsService.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Применить позицию рабочего места — единый переход для шагов
  /// «назад/вперёд» и переходов из встроенных экранов (B10 этап 2).
  /// Записи стека в split помечены панелью-владельцем ('paneIdx'):
  /// шаг применяется своей панели и возвращает ей фокус (ревью
  /// B10-2, находка 1); записи без метки — активной панели.
  /// Свайпы/ссылки идут напрямую в свою панель.
  void _applyLocation(Location loc, [String? banner]) {
    final owner = loc.pane['paneIdx'] as int?;
    final index = (owner != null && owner < panes.length) ? owner : activePane;
    if (owner != null) activePane = index;
    _applyLocationFor(index, loc, banner);
  }

  /// Применить позицию рабочего места к панели [index] — единый
  /// переход для свайпов, ссылок и шагов «назад/вперёд»: перевод,
  /// глава, снимок панели, прокрутка до стиха, журнал. Новых экранов
  /// не создаёт.
  void _applyLocationFor(int index, Location loc, [String? banner]) {
    // Внешний экран как позиция рабочего места: читалка остаётся
    // под ним, _overlayScreen() в build показывает нужный экран.
    if (loc.kind == 'screen') {
      // Чтение вслух не глушим: слушать главу, пока открыты
      // Поиск/История, — ожидаемый сценарий.
      setState(() {});
      return;
    }
    final p = panes[index];
    // Переход на стих не убивает чтение вслух: глушим текущую
    // очередь, но если оно шло — запоминаем стих возобновления;
    // как только новая глава догрузится (_load/_ensureChapter),
    // очередь перезапустится с этого места. Очередь принадлежит
    // панели-владельцу (ttsOwnerPane, B10 этап 2): навигация в
    // чужой панели чтение не глушит и не возобновляет.
    if (ttsOwnerPane == index) {
      final wasPlaying = _ttsPlaying;
      _stopTts();
      if (wasPlaying) {
        final target = loc.verse > 0
            ? loc.verse
            : (progress.lastVerse['${loc.book}:${loc.chapter}'] ?? 1);
        _ttsResumeChapter = (
          book: loc.book,
          chapter: loc.chapter,
          verse: target,
        );
      }
    }
    final cmp = loc.pane['cmp'] as String?;
    // Позиция панели — состояние контроллера (B10 этап 1): мутации
    // напрямую, одна нотификация на переход (бывший setState).
    p._moduleId = loc.moduleId;
    p._code = loc.book;
    p._ch = loc.chapter;
    p._selectedVerse = null;
    _notesOpen = false;
    p._interleaved = loc.pane['interleaved'] as bool? ?? p._interleaved;
    if (cmp != null && cmp != p._moduleId) p._compareModuleId = cmp;
    final cmps = loc.pane['cmps'] as String?;
    // Список сравнения — состояние панели позиции, не настройка:
    // навигация не должна переписывать глобальную (ADR 0030).
    if (cmps != null) p._interleavedOverride = cmps;
    // Пресет раскладки едет в снимке позиции (B10 этап 2): шаги
    // «назад/вперёд» возвращают и его; позиция без ключа — ручная
    // раскладка.
    _activePresetId = loc.pane['preset'] as String?;
    // Режим «две панели» и позиция пассивной панели едут в снимке
    // (B10 этап 2); отсутствие ключа раскладку не меняет.
    _restoreSplit(loc);
    // Пассивная панель восстанавливается из снимка «other» — своя
    // позиция у каждой панели (ревью B10-2, находка 1). Связанные
    // панели дальше доведёт взаимная синхронизация; отвязанная
    // остаётся на своём месте.
    if (_split) {
      final other = loc.pane['other'];
      if (other is Map && panes.length > 1) {
        final o = panes[index == 0 ? 1 : 0];
        // Программный прыжок: проводку скролла глушим.
        _crossSyncing = true;
        o.applySyncedVerse(
          other['module'] as String? ?? o._moduleId,
          other['book'] as String? ?? o._code,
          (other['ch'] as num?)?.toInt() ?? o._ch,
          (other['v'] as num?)?.toInt() ?? 0,
        );
        _crossSyncing = false;
      }
    }
    p._blockKeys.clear();
    p._bookVerseKeys.clear();
    p.rebuild();
    if (p._scroll.hasClients) p._scroll.jumpTo(0);
    if (p._compareScroll.hasClients) p._compareScroll.jumpTo(0);
    p._load(p._moduleId);
    p._loadVerseEntries();
    // Прогресс и журнал чтения — активной панели (B10 этап 2):
    // позиция пассивной панели в них не пишется.
    if (index == activePane) {
      progress.markRead(loc.book, loc.chapter);
      progress.setPosition(loc.book, loc.chapter);
      history.touch(loc.moduleId, loc.book, loc.chapter, verse: loc.verse);
    }
    // Главы соседних экранов .sb подгружаем по месту.
    for (final m in p._mods.values) {
      p._ensureChapter(m, loc.book, loc.chapter);
    }
    // Восстановление — до стиха, не до пикселя (ADR 0019).
    final target = loc.verse > 0
        ? loc.verse
        : progress.lastVerse['${loc.book}:${loc.chapter}'];
    p._scrollToVerse(target);
    // Взаимная синхронизация: переход панели ведёт связанные панели
    // за ней (B10 этап 2).
    _onPaneNavigated(index, loc.moduleId, loc.book, loc.chapter, loc.verse);
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

  /// Взаимная синхронизация связанных панелей (B10 этап 2): переход
  /// панели с группой [ReaderPaneController.linkGroup] ведёт остальные
  /// панели группы за ней — книга/глава те же, стих конвертируется
  /// в версификацию модуля панели-приёмника. Стек не пишется: запись
  /// делает панель, где был пользователь (applySyncedVerse). Флаг
  /// [_syncing] страхует от цикла, отвязанная панель не следует.
  Future<void> _onPaneNavigated(
    int index,
    String moduleId,
    String book,
    int chapter,
    int verse,
  ) async {
    if (_syncing || !_split) return;
    final src = panes[index];
    if (src.linkGroup.isEmpty) return;
    _syncing = true;
    // Программные прыжки ведомой панели не порождают проводку скролла.
    _crossSyncing = true;
    try {
      // Копия списка: закрытие split посреди конверсии меняет panes
      // (ревью B10-2, находка 3).
      for (final o in [...panes]) {
        if (identical(o, src) || o.linkGroup != src.linkGroup) continue;
        var t = (book: book, chapter: chapter, verse: verse);
        if (o._moduleId != moduleId) {
          final conv = await o._convFromPane(src, book, chapter, verse);
          // Лидер ушёл дальше, пока шла конверсия, — устаревшее не
          // применяем: следующий переход проведёт синхронизацию заново
          // (ревью B10-2, находка 2).
          if (src._code != book || src._ch != chapter) return;
          if (conv == null) continue; // соответствия нет — панель на месте
          t = conv;
        }
        if (!mounted || !_split) return;
        o.applySyncedVerse(o._moduleId, t.book, t.chapter, t.verse);
      }
    } finally {
      _syncing = false;
      _crossSyncing = false;
    }
    // Связанная панель ушла за ведущей — рабочее место изменилось.
    if (mounted) _scheduleWorkspaceSave();
  }

  /// Проводка скролла между связанными панелями (B10 этап 2): прокрутка
  /// панели [from] пропорционально ведёт панель [to] — как колонка
  /// сравнения, но между панелями. Работает при открытом split и связи
  /// «main»; программные прыжки (applySyncedVerse) гасятся флагом
  /// [_crossSyncing].
  void _crossScrollSync(int from, int to) {
    if (!_split || _crossSyncing || panes.length < 2) return;
    if (panes[from].linkGroup.isEmpty ||
        panes[from].linkGroup != panes[to].linkGroup) {
      return;
    }
    final leader = panes[from]._scroll;
    final follower = panes[to]._scroll;
    if (!leader.hasClients || !follower.hasClients) return;
    if (leader.positions.length != 1 || follower.positions.length != 1) {
      return;
    }
    if (leader.position.maxScrollExtent <= 0 ||
        follower.position.maxScrollExtent <= 0) {
      return;
    }
    _crossSyncing = true;
    follower.jumpTo(
      (leader.offset /
              leader.position.maxScrollExtent *
              follower.position.maxScrollExtent)
          .clamp(0.0, follower.position.maxScrollExtent),
    );
    _crossSyncing = false;
  }

  /// Лента панелей чтения (B10 этап 2): одна колонка — прежняя
  /// раскладка; две — с перетаскиваемой границей [splitRatio].
  Widget _panesRow(Palette p, bool wide) {
    return LayoutBuilder(
      builder: (context, cons) => Row(
        children: [
          _paneColumn(0, p, wide),
          if (_split) ...[
            _splitDivider(p, cons.maxWidth),
            _paneColumn(1, p, wide),
          ],
        ],
      ),
    );
  }

  /// Доля ширины панели в ленте, промилле (граница 0.25–0.75).
  int _splitFlex(int index) {
    if (!_split) return 1;
    final w = (splitRatio * 1000).round().clamp(250, 750);
    return index == 0 ? w : 1000 - w;
  }

  /// Колонка панели: свайп-листание + тело главы + (широкий экран)
  /// колонка сравнения. Тап в любой точке фокусирует панель; в
  /// режиме «две панели» активная помечена тонкой акцентной кромкой
  /// сверху, а шапка колонки несёт кнопку связи ([_paneLinkHeader]).
  /// У каждой колонки свой ReaderPageSwipe и свой скролл.
  Widget _paneColumn(int index, Palette p, bool wide) {
    final c = panes[index];
    final ch = c._module?.chapter(c._code, c._ch);
    final active = _split && index == activePane;
    return Expanded(
      flex: _splitFlex(index),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              width: 2,
              color: active ? p.accent : Colors.transparent,
            ),
          ),
        ),
        child: Column(
          children: [
            // Шапка колонки — только в режиме «две панели» (B10
            // этап 2): зазор под верхней панелью + кнопка связи.
            // В одной панели надстройки нет — раскладка прежняя.
            if (_split) ...[
              SizedBox(height: MediaQuery.of(context).padding.top + 56),
              _paneLinkHeader(index, p),
            ],
            Expanded(
              child: Listener(
                // Фокус панели: любая касательная (тап, прокрутка, свайп)
                // делает колонку активной (B10 этап 2).
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _setActivePane(index),
                child: NotificationListener<ScrollNotification>(
                  // Прокрутка текста прячет панель управления — только
                  // нотифаер хрома, текст главы не перестраивается (ADR 0030).
                  onNotification: (n) {
                    if (n is ScrollUpdateNotification && _barVisN.value) {
                      _barVisN.value = false;
                    }
                    return false;
                  },
                  child: ReaderPageSwipe<(String, int, String?)>(
                    targetFor: c._goTarget,
                    prepareTarget: (t) {
                      final m = c._module;
                      if (m != null) c._ensureChapter(m, t.$1, t.$2);
                    },
                    peekBuilder: (t) =>
                        c._peekPage(context, p, wide, t.$1, t.$2),
                    canStart: () =>
                        c._selectedText == null || c._selectedText!.isEmpty,
                    onTap: () {
                      if (!_barVisible) {
                        setState(() => _barVisible = true);
                      }
                    },
                    onCommit: c._go,
                    child: Row(
                      children: [
                        Expanded(
                          child: Directionality(
                            textDirection: c._isRtl
                                ? TextDirection.rtl
                                : TextDirection.ltr,
                            child: c._readingBody(context, ch, p, wide),
                          ),
                        ),
                        if (c._compare && wide && !c._interleaved)
                          c._compareBody(p),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Шапка колонки панели в режиме «две панели» (B10 этап 2): кнопка
  /// связи — привязать панель к основной группе ('main') или отвязать
  /// (''). У левой колонки кнопка у разделителя (справа), у правой —
  /// тоже у разделителя (слева).
  Widget _paneLinkHeader(int index, Palette p) {
    final linked = panes[index].linkGroup.isNotEmpty;
    final btn = IconButton(
      tooltip: linked
          ? tr('Отвязать панель', 'Unlink pane')
          : tr('Связать с основной', 'Link to main'),
      icon: Icon(
        linked ? Icons.link : Icons.link_off,
        size: 18,
        color: linked ? p.accent : p.muted,
      ),
      visualDensity: VisualDensity.compact,
      onPressed: () => _togglePaneLink(index),
    );
    return SizedBox(
      height: 34,
      child: Row(
        children: index == 0
            ? [const Spacer(), btn, const SizedBox(width: 6)]
            : [const SizedBox(width: 6), btn, const Spacer()],
      ),
    );
  }

  /// Перетаскиваемая граница панелей (B10 этап 2): ручка 8px, драг
  /// ведёт [splitRatio] в пределах 0.25–0.75. По концу драга —
  /// отложенная запись рабочего места.
  Widget _splitDivider(Palette p, double rowWidth) {
    return SizedBox(
      width: 8,
      child: GestureDetector(
        key: const ValueKey('split-divider'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) {
          if (rowWidth <= 0) return;
          setState(() {
            splitRatio = ((splitRatio * rowWidth + d.delta.dx) / rowWidth)
                .clamp(0.25, 0.75)
                .toDouble();
          });
        },
        onHorizontalDragEnd: (_) {
          // Пользователь выбирал отношение сам — пресеты его не трогают.
          _ratioTouched = true;
          _scheduleWorkspaceSave();
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: Center(child: Container(width: 1.5, color: p.edge)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      // ← → на клавиатуре листают главы (как свайпы на телефоне).
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => pane._go(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => pane._go(-1),
      },
      child: Focus(
        autofocus: true,
        // Alt+←/→ — шаги по стеку позиций рабочего места, как
        // в браузере (десктоп; ADR 0019).
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent ||
              !HardwareKeyboard.instance.isAltPressed) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _stackBack();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _stackForward();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        // Системный «назад» — сначала шаг по стеку рабочего места;
        // стек пуст — обычный pop (на «Домой»/к открывшему экрану).
        // Открытые листы/меню закрывает само дерево виджетов раньше.
        child: PopScope(
          canPop: _allowRoutePop,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // Порядок закрытия (ADR 0019): шторки/меню закрывает
            // дерево само; поле поиска — следующим; затем стек.
            if (_searchOpenN.value) {
              _searchOpenN.value = false;
              return;
            }
            final loc = workspace.back();
            if (loc != null) {
              _applyLocation(loc);
            } else {
              _popRoute(() => Navigator.of(context).maybePop());
            }
          },
          // Боковые кнопки мыши X1/X2 — шаги по стеку (десктоп).
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) {
              if (e.buttons == kBackMouseButton) {
                _stackBack();
              } else if (e.buttons == kForwardMouseButton) {
                _stackForward();
              }
            },
            // Панечно-волатильное состояние — в контроллерах (B10
            // этап 1): текст главы и хром перестраиваются их
            // нотификацией; экранное setState остаётся хрому и стеку.
            // В режиме «две панели» перестройка любой панели (в т.ч.
            // пассивной — синхронизацией или догрузкой главы) тоже
            // обновляет экран.
            child: ListenableBuilder(
              listenable: Listenable.merge(panes),
              builder: (context, _) {
                final p = context.palette;
                final wide = MediaQuery.of(context).size.width >= 700;
                final group = kBookGroup[pane._code] ?? BookGroup.torah;
                final color = groupColor(group, appThemeOf(context));
                final ch = pane._module?.chapter(pane._code, pane._ch);
                final notes = ch == null
                    ? <({int verse, NoteSpanDoc note})>[]
                    : pane._notesOf(ch);

                return _overlayScreen() ??
                    Scaffold(
                      // Боковая панель сносок — снаружи Stack: верхний бар
                      // перекрывает только колонку текста, заголовок панели
                      // виден всегда (десктоп/веб).
                      body: Row(
                        children: [
                          Expanded(
                            child: Stack(
                              children: [
                                // Лента панелей: одна — прежняя раскладка,
                                // две — с границей [splitRatio] (B10 этап 2).
                                _panesRow(p, wide),
                                // Верхняя панель: назад + «Книга Гл.» + поле поиска.
                                // На десктопе она же несёт все кнопки управления; на
                                // телефоне кнопки живут в нижней панели.
                                // Хром слушает свои нотифаеры (ADR 0030):
                                // скрытие бара не пересобирает текст главы.
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: 0,
                                  child: ListenableBuilder(
                                    listenable: _barVisN,
                                    builder: (_, _) => AnimatedSlide(
                                      offset: _barVisN.value
                                          ? Offset.zero
                                          : const Offset(0, -1),
                                      duration: const Duration(
                                        milliseconds: 250,
                                      ),
                                      curve: Curves.easeOut,
                                      child: AnimatedOpacity(
                                        opacity: _barVisN.value ? 1.0 : 0.0,
                                        duration: const Duration(
                                          milliseconds: 250,
                                        ),
                                        child: _topBar(p, color, wide: wide),
                                      ),
                                    ),
                                  ),
                                ),
                                // Нижняя панель кнопок — только на узком экране.
                                if (!wide)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: ListenableBuilder(
                                      listenable: _barVisN,
                                      builder: (_, _) => AnimatedSlide(
                                        offset: _barVisN.value
                                            ? Offset.zero
                                            : const Offset(0, 1),
                                        duration: const Duration(
                                          milliseconds: 250,
                                        ),
                                        curve: Curves.easeOut,
                                        child: AnimatedOpacity(
                                          opacity: _barVisN.value ? 1.0 : 0.0,
                                          duration: const Duration(
                                            milliseconds: 250,
                                          ),
                                          child: _controlBar(
                                            p,
                                            color,
                                            wide: wide,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                // Плавающее поле поиска — над нижней панелью, не
                                // закрывает текст (мобильная раскладка).
                                if (!wide)
                                  Positioned(
                                    left: 12,
                                    right: 12,
                                    bottom:
                                        MediaQuery.of(context).padding.bottom +
                                        66 +
                                        (_ttsPlaying ? 64 : 0),
                                    child: ListenableBuilder(
                                      listenable: _searchOpenN,
                                      builder: (_, _) => _searchOpenN.value
                                          ? _searchField(p)
                                          : const SizedBox.shrink(),
                                    ),
                                  ),
                                // «Очки» — плавающий переключатель
                                // Чтение ↔ Изучение (ADR 0015): справа
                                // внизу над нижней панелью; живёт и
                                // прячется вместе с остальным хромом.
                                Positioned(
                                  right: 16,
                                  bottom:
                                      MediaQuery.of(context).padding.bottom +
                                      (wide ? 16 : 76),
                                  child: ListenableBuilder(
                                    listenable: _barVisN,
                                    builder: (_, _) => _searchOpenN.value
                                        ? const SizedBox.shrink()
                                        : AnimatedSlide(
                                            offset: _barVisN.value
                                                ? Offset.zero
                                                : const Offset(0, 0.4),
                                            duration: const Duration(
                                              milliseconds: 250,
                                            ),
                                            curve: Curves.easeOut,
                                            child: AnimatedOpacity(
                                              opacity: _barVisN.value
                                                  ? 1.0
                                                  : 0.0,
                                              duration: const Duration(
                                                milliseconds: 250,
                                              ),
                                              child: _glassesFab(p),
                                            ),
                                          ),
                                  ),
                                ),
                                // «Оглавление» — плавающая кнопка выбора
                                // книги/главы слева внизу, пара к «очкам»;
                                // тот же ритм появления/скрытия.
                                Positioned(
                                  left: 16,
                                  bottom:
                                      MediaQuery.of(context).padding.bottom +
                                      (wide ? 16 : 76),
                                  child: ListenableBuilder(
                                    listenable: _barVisN,
                                    builder: (_, _) => _searchOpenN.value
                                        ? const SizedBox.shrink()
                                        : AnimatedSlide(
                                            offset: _barVisN.value
                                                ? Offset.zero
                                                : const Offset(0, 0.4),
                                            duration: const Duration(
                                              milliseconds: 250,
                                            ),
                                            curve: Curves.easeOut,
                                            child: AnimatedOpacity(
                                              opacity: _barVisN.value
                                                  ? 1.0
                                                  : 0.0,
                                              duration: const Duration(
                                                milliseconds: 250,
                                              ),
                                              child: _bookFab(p),
                                            ),
                                          ),
                                  ),
                                ),
                                // Мини-плеер чтения вслух: пауза/перемотка по стихам,
                                // плавает над нижней панелью и остаётся, когда панели
                                // спрятаны прокруткой. Виден и в паузе перехода
                                // (_ttsResumeChapter): смена главы не заставляет его
                                // мигать. Позиция ведётся нотифаером бара (ADR 0030):
                                // скрытие панели уводит плеер вниз сразу, не дожидаясь
                                // тика следующего стиха.
                                if (_ttsPlaying || _ttsResumeChapter != null)
                                  ValueListenableBuilder<bool>(
                                    valueListenable: _barVisN,
                                    builder: (_, visible, _) =>
                                        AnimatedPositioned(
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          curve: Curves.easeOut,
                                          left: 12,
                                          right: 12,
                                          bottom: (visible && !wide)
                                              ? MediaQuery.of(context)
                                                        .padding
                                                        .bottom +
                                                    64
                                              : MediaQuery.of(context)
                                                        .padding
                                                        .bottom +
                                                    12,
                                          child: _ttsPlayer(p),
                                        ),
                                  ),
                              ],
                            ),
                          ),
                          if (wide)
                            ListenableBuilder(
                              listenable: _notesOpenN,
                              builder: (_, _) => _notesOpenN.value
                                  ? Container(
                                      width: 360,
                                      decoration: BoxDecoration(
                                        color: p.card,
                                        border: Border(
                                          left: BorderSide(color: p.edge),
                                        ),
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
                                                icon: const Icon(
                                                  Icons.close,
                                                  size: 18,
                                                ),
                                                onPressed: () =>
                                                    _notesOpenN.value = false,
                                              ),
                                            ],
                                          ),
                                          Expanded(
                                            child: NotesSheet(
                                              notes: notes,
                                              selectedVerse:
                                                  pane._selectedVerse,
                                              // Контроллер — поле состояния:
                                              // создание здесь сбрасывало
                                              // скролл панели при каждой
                                              // пересборке (BUGS 18.10.2026).
                                              controller: _notesCtrl,
                                              onRef: pane._goToRef,
                                              variants:
                                                  ch?.variants ?? const [],
                                              openModule: pane._moduleId,
                                              fromVrs:
                                                  pane._module?.versification ??
                                                  '',
                                              onOpenModule: pane._goToRefModule,
                                              panelLoader: pane._panelLoader(
                                                pane._ch,
                                              ),
                                              metaLoader: pane._metaLoader(
                                                pane._ch,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                        ],
                      ),
                    );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Внешний экран (Поиск/История/«Все переводы») как позиция
  /// рабочего места — не новый маршрут: «назад»/Alt+←/X1 ведут
  /// к прежнему стиху по единому стеку (ADR 0019).
  void _openScreen(String name, [Map<String, Object?> extra = const {}]) {
    workspace.go(
      Location(
        kind: 'screen',
        moduleId: pane._moduleId,
        book: pane._code,
        chapter: pane._ch,
        pane: {'screen': name, ...extra},
      ),
    );
    // Чтение вслух не глушим: поиск/история при звучащей главе —
    // нормальный сценарий (экран — не смена места чтения).
    setState(() {});
  }

  /// Встроенный экран текущей позиции стека (null — позиция-стих,
  /// показываем читалку). Переход к стиху из встроенного экрана —
  /// шаг стека, а не новый маршрут.
  Widget? _overlayScreen() {
    final loc = workspace.current;
    if (loc == null || loc.kind != 'screen') return null;
    void openVerse(String module, String book, int chapter, int verse) {
      final l = Location.verse(
        moduleId: module,
        book: book,
        chapter: chapter,
        verse: verse,
        pane: pane._paneSnapshot(),
      );
      workspace.go(l);
      _applyLocation(l);
    }

    return switch (loc.pane['screen']) {
      'history' => HistoryScreen(
        onBack: _stackBack,
        onOpenVerse: openVerse,
        // «Все вхождения» из карточки Стронга: на экран поиска —
        // обратный поиск по номеру.
        onFinStrongVerses: (s) => _openScreen('search', {
          'module': pane._moduleId,
          'q': s,
        }),
      ),
      'search' => SearchScreen(
        moduleId: loc.pane['module'] as String? ?? pane._moduleId,
        initialBook: loc.pane['book'] as String? ?? pane._code,
        initialQuery: loc.pane['q'] as String?,
        onBack: _stackBack,
        onOpenVerse: openVerse,
      ),
      'compare' => VerseCompareScreen(
        bookCode: loc.pane['book'] as String? ?? pane._code,
        chapter: loc.pane['ch'] as int? ?? pane._ch,
        verse: loc.pane['v'] as int? ?? 0,
        fromVrs: loc.pane['vrs'] as String? ?? '',
        onBack: _stackBack,
        onOpenVerse: openVerse,
      ),
      _ => null,
    };
  }

  /// Шаг по стеку позиций назад: PopScope, Alt+←, кнопка мыши X1.
  /// Стек пуст — обычный выход с экрана.
  void _stackBack() {
    final loc = workspace.back();
    if (loc != null) {
      _applyLocation(loc);
    } else {
      _popRoute(() => Navigator.of(context).maybePop());
    }
  }

  /// Шаг по стеку вперёд: Alt+→, кнопка мыши X2.
  void _stackForward() {
    final loc = workspace.forward();
    if (loc != null) _applyLocation(loc);
  }

  /// Отпущен ли pop маршрута (PopScope перехватывает «назад» ради
  /// стека workspace; кнопка шапки «уровень вверх» отпускает его
  /// на один кадр через [_popRoute]).
  bool _allowRoutePop = false;

  /// Выполнить pop маршрута, минуя перехват PopScope: поднимаем
  /// [_allowRoutePop] и ждём пересборки кадра.
  void _popRoute(void Function() action) {
    setState(() => _allowRoutePop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      action();
      if (mounted) setState(() => _allowRoutePop = false);
    });
  }

  /// Кнопка «назад» в шапке — всегда вверх по иерархии: глава →
  /// сетка глав текущей книги (ROADMAP 1.0.2). Не шаг по стеку
  /// позиций: из сетки — pop на ту же сетку; из чужого места или
  /// после свайпа в другую книгу — замена на сетку текущей книги.
  void _hierarchyBack() => _popRoute(() {
    if (widget.openedFromGrid && pane._code == widget.bookCode) {
      Navigator.of(context).maybePop();
    } else {
      Navigator.of(context)
          .pushReplacement(fastRoute(ChapterGridScreen(bookCode: pane._code)));
    }
  });
}
