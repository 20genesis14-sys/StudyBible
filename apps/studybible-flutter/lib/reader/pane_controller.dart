part of '../screens/reading_screen.dart';

/// Контроллер панели чтения (B10 этап 1, ADR 0014): панечно-волатильное
/// состояние — позиция, записи пользователя, кэши рендера, скролл —
/// покидает `_ReadingScreenState`; рендер следует за контроллером.
///
/// Живёт в одной библиотеке с экраном (part): приватные имена частей
/// доступны как раньше,ownership меняется, имена сохраняются.
/// Экранное (не панечное) состояние — TTS-сервис, хром на нотифаерах,
/// стек рабочего места — остаётся на `_ReadingScreenState`; что нужно
/// контроллеру из экранного, входит через хуки конструктора
/// (`applyLocation`, `ttsVerseOf`, `onSelectVerse`…).
class ReaderPaneController extends ChangeNotifier {
  ReaderPaneController({
    required this.index,
    required this.isAlive,
    required this.initialVerse,
    required String bookCode,
    required int chapter,
    String? moduleId,
    required this.applyLocation,
    required this.openScreen,
    required this.ttsVerseOf,
    required this.ttsWordOf,
    required this.ttsWordN,
    required this.cancelTtsResume,
    required this.resumeTtsAfterNavigation,
    required this.onSelectVerse,
    required this.onOpenNotes,
    this.linkGroup = 'main',
    this.snapshotExtra = _noSnapshotExtra,
  }) : _code = bookCode,
       _ch = chapter,
       _moduleId = moduleId ?? mainModuleId();

  /// Пустая надстройка снимка — значение по умолчанию: снимок остаётся
  /// прежним в одной панели.
  static Map<String, Object?> _noSnapshotExtra() => const {};

  /// Индекс панели на экране: 0 — единственная/левая, 1 — правая в
  /// режиме «две панели» (B10 этап 2). Замыкается фабрикой экрана
  /// в хуки, чтобы переходы и тапы приходили в свою панель.
  final int index;

  /// Группа связи панелей (B10 этап 2): 'main' — связанные панели
  /// ходят за навигацией друг друга (взаимная синхронизация); ''
  /// — отвязанная панель живёт своей позицией.
  String linkGroup;

  /// Экранная надстройка снимка панели (B10 этап 2): режим «две
  /// панели» ('split'), отношение сторон ('ratio') и позиция
  /// пассивной панели ('other') едут в снимке стека вместе с
  /// панечными ключами. Пишет экран, контроллер только подмешивает.
  final Map<String, Object?> Function() snapshotExtra;

  /// Проверка «экран жив» вместо `mounted`: контроллер о виджете не
  /// знает, асинхронные продолжения спрашивают хук (экран передаёт
  /// `() => mounted`).
  final bool Function() isAlive;

  /// Панель удалена (закрытие split): экран жив, а контроллеру
  /// уведомлять больше нельзя — находка 4 ревью B10-2.
  bool _disposed = false;

  bool get _alive => isAlive() && !_disposed;

  /// Стартовый стих ссылки (`widget.verse`): вторая прокрутка в [_load],
  /// когда глава основного модуля догрузится.
  final int? initialVerse;

  /// Хук экранного уровня: единый переход на позицию стека
  /// (`_applyLocation`) — стек рабочего места остаётся на экране.
  final void Function(Location loc, [String? banner]) applyLocation;

  /// Хук экранного уровня: открыть встроенный экран рабочего места
  /// (Поиск/История/«Все переводы»).
  final void Function(String name, [Map<String, Object?> extra]) openScreen;

  /// Хук: читаемый вслух стих — TTS-сервис остаётся на экране.
  final int? Function() ttsVerseOf;

  /// Хук: текущее слово чтения вслух — TTS-сервис остаётся на экране.
  final WordMark? Function() ttsWordOf;

  /// Нотифаер слова чтения вслух (ADR 0030): им владеет экран,
  /// динамические строки панели на него подписываются.
  final ValueNotifier<WordMark?> ttsWordN;

  /// Хук: погасить отложенное возобновление чтения вслух.
  final void Function() cancelTtsResume;

  /// Хук: возобновить чтение вслух после догрузки главы.
  final void Function([ModuleDoc? doc]) resumeTtsAfterNavigation;

  /// Хук: тап по стиху (меню действий — экранное, панель сносок —
  /// хром на нотифаере экрана).
  final void Function(int v, [int? chCtx]) onSelectVerse;

  /// Хук: открыть панель сносок (владелец — экран).
  final void Function() onOpenNotes;

  /// Текущая раскладка ADR 0014: одна панель чтения.
  /// Дальнейшие шаги рефакторинга передают её в ReaderPane.
  /// Имя не `workspace` — не затеняет глобальный синглтон позиций.
  final WorkspaceConfig layout = WorkspaceConfig.singleReader();

  final Map<String, ModuleDoc> _mods = {};
  String _moduleId;
  String _code;
  int _ch;
  bool _compare = false;

  /// Строчное сравнение: под каждым стихом основного перевода —
  /// тот же стих второго перевода (макет будущего подстрочника).
  bool _interleaved = false;
  int? _selectedVerse;

  /// Позиция последнего тапа по тексту — якорь всплывающего
  /// меню стиха (меню открывается рядом с местом нажатия).
  Offset _lastTapPos = Offset.zero;

  /// Второй перевод в режиме сравнения.
  ///
  /// Хранится только явный выбор пользователя; если его не было,
  /// эффективный [_compareModuleId] берёт первый установленный модуль,
  /// отличный от основного (динамический дефолт: следует и за набором
  /// модулей, и за сменой основного перевода).
  String? _compareModuleIdExplicit;

  /// Эффективный второй перевод или null, когда сравнивать не с чем
  /// (явного выбора нет, а установлен единственный модуль).
  String? get _compareModuleIdOrNull {
    final explicit = _compareModuleIdExplicit;
    if (explicit != null) return explicit;
    for (final id in installedModules.keys) {
      if (id != _moduleId) return id;
    }
    return null;
  }

  /// Эффективный второй перевод — не-null для читателей вне этого
  /// файла (reader_pane, chapter_renderer). При единственном
  /// установленном модуле последним рубежом остаётся прежний
  /// литеральный дефолт: модуль не установлен — колонка сравнения
  /// покажет «не выгружена», как и раньше.
  String get _compareModuleId =>
      _compareModuleIdOrNull ?? (_moduleId == 'engwebp' ? 'russyn' : 'engwebp');

  set _compareModuleId(String v) => _compareModuleIdExplicit = v;

  final ScrollController _compareScroll = ScrollController();

  /// Кэши конверсии версификаций по каждому модулю сравнения:
  /// targetId -> карта «стих основного -> координаты в target»
  /// (вопрос 8). null-значение — одинаковые версификации или ещё
  /// не посчитано (тогда используется тот же номер — короткий путь).
  final Map<String, Map<int, List<CvPoint>>?> _convs = {};

  /// Ключи кэшей конверсии: targetId -> 'книга:глава:основной->target'.
  final Map<String, String> _convKeys = {};

  /// Защита от обратного вызова при синхронной прокрутке колонок.
  bool _syncingScroll = false;

  /// verse -> ключ блока, где стих начинается (для прокрутки).
  final Map<int, GlobalKey> _blockKeys = {};

  /// В ленте «книга» номера стихов повторяются между главами,
  /// поэтому ключ — «глава:стих».
  final Map<String, GlobalKey> _bookVerseKeys = {};
  final ScrollController _scroll = ScrollController();

  /// Ленивая глава: стих → индекс его строки в списке элементов
  /// (без учёта заголовка; +1 на месте использования). Заполняется
  /// в построителях главы; пусто в абзацном режиме — там оценка
  /// идёт по карте стих→блок.
  final Map<int, int> _verseItemIndex = {};

  /// Число элементов ленивой ленты главы (заголовок + строки).
  int _itemsTotal = 0;

  /// Записи к стихам текущей главы: verse -> запись.
  /// Выделений у стиха может быть несколько (куски разных цветов,
  /// схема 4) — поэтому список.
  final Map<int, List<UserEntry>> _highlights = {};
  final Map<int, UserEntry> _verseNotes = {};

  /// Разрешённые диапазоны частичных выделений: verse -> срезы
  /// (запись + UTF-16 смещения в плоском тексте стиха без тримма).
  /// Считаются при загрузке записей через fragRanges моста.
  final Map<int, List<({UserEntry rec, int s, int e})>> _hlFrags = {};

  /// Заметки к выделенным фразам (note + frag, схема 4):
  /// verse -> записи. Связь с выделением — по совпадению frag.
  final Map<int, List<UserEntry>> _fragNotes = {};

  /// Стих под pointer-down в начале выделения — основная привязка
  /// для внутристишовых кусков без маркеров « N » (Listener на
  /// SelectionArea, `_verseAtPoint` по ключам _blockKeys).
  int? _selAnchorVerse;

  /// Закладки и теги стихов главы: verse -> запись.
  final Map<int, UserEntry> _verseMarks = {};
  final Map<int, UserEntry> _tagEntries = {};

  /// Текст последнего выделения в SelectionArea — для меню действий
  /// со стихами (копируется текстом с номерами стихов).
  String? _selectedText;

  final _tapRecognizers = <GestureRecognizer>{};
  Map<String, LexiconEntry>? _lex;

  /// Кэш построенных строк главы (ADR 0030): строки стихов (`L:`),
  /// блоки абзацев (`B:`), строки сравнения (`I:`), вторые строки
  /// (`S:`) и подстрочник (`P:`). Инвалидируется сменой сигнатуры
  /// `_lineSig` (глава, модули, настройки отображения, палитра,
  /// словарь, конверсии) и перечиткой записей пользователя.
  final ChapterLineCache _chapterCache = ChapterLineCache();
  String _lineSig = '';

  /// Партия распознавателей текущей строки: открытая партия собирает
  /// их для записи кэша, закрытая уходит во временную ротацию
  /// (ADR 0030).
  final _lineRecs = <GestureRecognizer>[];
  bool _recsOpen = false;

  /// Распознаватели тапов прошлого кадра: динамические строки и
  /// заголовки пересоздаются при каждом build, старые recognizer'ы
  /// надо dispose'ить после кадра (на длинных главах в «Изучении»
  /// иначе копятся сотни).
  final _tapRecognizersOld = <GestureRecognizer>{};
  bool _tapGcQueued = false;

  /// Список модулей строчного сравнения из снимка позиции стека
  /// (ADR 0019): перекрывает настройку на время позиции и не пишет её
  /// (раньше навигация переписывала глобальную настройку).
  String? _interleavedOverride;

  /// Панечная раскладка мобильного сравнения: «основной»/«второй».
  String _mobilePane = 'main';

  /// Поиск стиха в ленте книги уже идёт (ленивый ListView).
  bool _seeking = false;

  /// Pinch-zoom основного текста (fontScale): отслеживаемые пальцы,
  /// дистанция и масштаб на старте щипка; _pinching — жест двумя
  /// пальцами реально начался (сохранять настройку по концу).
  final Map<int, Offset> _pinchPtrs = {};
  double _pinchDist0 = 0;
  double _pinchFont = 1.0;
  bool _pinching = false;

  ModuleDoc? get _module => _mods[_moduleId];

  /// Снимок состояния панели для записи стека (ADR 0019):
  /// «назад» восстанавливает строчное сравнение и его перевод;
  /// поверх — экранная надстройка режима «две панели» (B10 этап 2).
  Map<String, Object?> _paneSnapshot() => {
    'interleaved': _interleaved,
    'cmp': _compareModuleId,
    'cmps': _interleavedOverride ?? settings.interleavedModules,
    ...snapshotExtra(),
  };

  /// Модули строчного сравнения по порядку показа (основной
  /// исключён); пустой список настроек — старый одиночный второй
  /// перевод. Снимок позиции перекрывает настройку (ADR 0030).
  /// Слой compare как вклад (ADR 0020): `modules: [...]`.
  List<String> get _compareIds {
    final raw = _interleavedOverride ?? settings.interleavedModules;
    final ids = raw
        .split(',')
        .where(installedModules.containsKey)
        .where((id) => id != _moduleId)
        .toList();
    if (ids.isEmpty) {
      final c = _compareModuleIdOrNull;
      if (c != null && c != _moduleId) ids.add(c);
    }
    return ids;
  }

  /// Перестроение панели: панечно-волатильные поля меняют напрямую,
  /// затем зовут [rebuild] (бывший `_rebuild(fn)` — мутации в замыкании
  /// упразднены). [fn] оставлен для совместимости сигнатуры и
  /// выполняется перед нотификацией.
  void rebuild([VoidCallback? fn]) {
    if (fn != null) fn();
    notifyListeners();
  }

  /// Единый отступ контента под плавающей верхней панелью:
  /// строка состояния + прогресс (2) + ряд кнопок (~48) + зазор.
  double _topClear(BuildContext context) =>
      MediaQuery.of(context).padding.top + 56;

  /// Отступ контента над нижней панелью кнопок (узкий экран).
  double _bottomClear(BuildContext context) =>
      MediaQuery.of(context).padding.bottom + 62;

  @override
  void dispose() {
    _disposed = true;
    for (final r in _tapRecognizers) {
      r.dispose();
    }
    _tapRecognizers.clear();
    for (final r in _tapRecognizersOld) {
      r.dispose();
    }
    _tapRecognizersOld.clear();
    for (final r in _lineRecs) {
      r.dispose();
    }
    _lineRecs.clear();
    _chapterCache.dispose();
    _scroll.dispose();
    _compareScroll.dispose();
    super.dispose();
  }
}
