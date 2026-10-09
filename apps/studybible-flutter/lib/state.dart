/// Настройки и пользовательский прогресс.
///
/// Настройки пока в памяти. Прогресс на нативных платформах
/// персистируется через Rust-мост в store::UserData (userdata.db
/// в каталоге данных); на web — только в памяти.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FontWeight;

import 'package:flutter/foundation.dart';

// Прогресс через мост; на web — заглушка без сохранения.
import 'native_bridge_stub.dart'
    if (dart.library.io) 'native_bridge_io.dart'
    if (dart.library.html) 'native_bridge_web.dart';
import 'native_bridge.dart' show UserEntry;
import 'data.dart' show installedModules, mainModuleId;
import 'theme.dart';

/// Два варианта вёрстки главы.
enum LayoutMode { paragraphs, versePerLine, book }

/// Режим экрана чтения (ADR 0015): «Чтение» — чистый текст без
/// учебных меток; «Изучение» — стих на строку, маркеры сносок,
/// параллельных мест и номеров Стронга.
enum ReaderMode { reading, study }

/// Ширина текстовой колонки на десктопе.
enum ColumnWidth { reading, full }

/// Шрифт основного текста главы.
enum ReadingFont {
  /// Literata — шрифт Google для чтения с экрана.
  literata,

  /// Gentium Book Plus — SIL, книжный набор с широкой поддержкой Unicode.
  gentium,

  /// Системный (Roboto/по умолчанию платформы).
  system,

  /// PT Serif — книжная антиква (ADR 0015).
  ptSerif,
}

/// Имя семейства из pubspec (null — системный).
String? readingFontFamily(ReadingFont f) => switch (f) {
  ReadingFont.literata => 'Literata',
  ReadingFont.gentium => 'GentiumBookPlus',
  ReadingFont.system => null,
  ReadingFont.ptSerif => 'PTSerif',
};

class Settings extends ChangeNotifier {
  AppTheme theme = AppTheme.light;

  /// Авто-ночной режим по времени (roadmap): [theme] остаётся
  /// дневной темой пользователя; ночью действует [nightTheme].
  bool autoNight = false;

  /// Границы ночи в минутах суток (по умолчанию 22:00–07:00);
  /// интервал через полночь поддержан.
  int nightStart = 22 * 60;
  int nightEnd = 7 * 60;

  /// Тема, подставляемая ночью (тёмная или AMOLED).
  AppTheme nightTheme = AppTheme.dark;

  /// Действующая тема с учётом автоночного режима — то, что
  /// показывает MaterialApp; выбор пользователя хранит [theme].
  AppTheme get effectiveTheme {
    if (!autoNight) return theme;
    final now = DateTime.now();
    final m = now.hour * 60 + now.minute;
    final night = nightStart <= nightEnd
        ? (m >= nightStart && m < nightEnd)
        : (m >= nightStart || m < nightEnd);
    return night ? nightTheme : theme;
  }

  AppTheme? _lastEffective;
  Timer? _nightTimer;

  /// Периодический пересчёт автоночи: тема меняется сама на
  /// границе интервала. Таймер живёт только пока режим включён —
  /// вызывается после загрузки и каждого [update].
  void _syncNightTimer() {
    if (autoNight && _nightTimer == null) {
      _lastEffective = effectiveTheme;
      _nightTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        final e = effectiveTheme;
        if (e != _lastEffective) {
          _lastEffective = e;
          notifyListeners();
        }
      });
    } else if (!autoNight && _nightTimer != null) {
      _nightTimer!.cancel();
      _nightTimer = null;
    }
  }

  /// Точка входа при старте приложения (после [load]).
  void startAutoNight() => _syncNightTimer();

  /// Масштаб шрифта: 0.8 – 1.6, шаг настройки.
  double fontScale = 1.0;

  /// Ступени насыщенности текста главы (wght): 0–3 → 400/500/600/700.
  static const kFontWeightSteps = [400, 500, 600, 700];

  /// Ступень насыщенности текста (0 — обычный).
  int fontWeightStep = 0;

  /// FontWeight текущей ступени насыщенности.
  FontWeight get readingWeight =>
      FontWeight.values[kFontWeightSteps[fontWeightStep] ~/ 100 - 1];

  /// Отдельный масштаб текста сносок (карточка «Сноска»).
  double footScale = 1.0;

  /// Отдельный масштаб текста параллельных мест (карточка «°»).
  double xrefScale = 1.0;

  LayoutMode layoutMode = LayoutMode.paragraphs;
  ColumnWidth columnWidth = ColumnWidth.full;

  /// Режим «Чтение» / «Изучение» (ADR 0015).
  ReaderMode readerMode = ReaderMode.reading;

  /// Слои учебных меток (лист «Слои», ADR 0014/0015): видны в режиме
  /// «Изучение»; выключенные скрывают маркеры даже там.
  bool layerFootnotes = true;
  bool layerXrefs = true;
  bool layerStrongs = true;

  /// Шрифт текста главы.
  ReadingFont readingFont = ReadingFont.literata;

  /// Полные имена книг на плитках сетки «Библия» (ADR 0015, ≥ 11 sp).
  bool bookFullNames = false;

  /// Показывать выбор стиха после выбора главы (тумблер из ТЗ).
  bool versePickerEnabled = false;

  /// Активный план чтения (id из assets/data/plans.json; '' — нет).
  String activePlan = '';

  /// Дата начала активного плана (ISO yyyy-mm-dd).
  String planStart = '';

  /// Перевод для текстов параллельных мест/сносок ('' — основной).
  String xrefModule = '';

  /// Переводы на экране «стих во всех переводах»
  /// (через запятую; '' — все установленные).
  String compareModules = '';

  /// Переводы строчного сравнения 3+ (через запятую, в порядке
  /// показа; '' — старый одиночный второй перевод, ADR 0020).
  String interleavedModules = '';

  /// Язык интерфейса: 'ru' | 'en'.
  String lang = 'ru';

  /// Раскладка названий книг: 'synodal' | 'modern'.
  String bookNames = 'synodal';

  /// Движок чтения вслух: 'auto' | 'system' | 'neural' (ADR 0017).
  String voiceEngine = 'auto';

  /// Выбор нейроголоса по языку: 'ru:pack-id,en:pack-id'.
  String neuralVoices = '';

  /// Скорость чтения 0.6–1.6 (множитель; у neural — speed VITS,
  /// у system — поверх привычных 0.45).
  double voiceRate = 1.0;

  /// Пословная подсветка читаемого стиха (у neural — оценочная).
  bool voiceWords = false;

  /// Автоударения русского текста нейромоделью (только бэкенд
  /// neural; ADR 0017 «Фронтенд языка»).
  bool voiceAccent = true;

  /// Системный TTS-движок (Android): имя пакета, '' — по умолчанию.
  String systemEngine = '';

  /// Голос системного движка: 'name|locale' (как у flutter_tts
  /// getVoices), '' — голос по умолчанию для языка.
  String systemVoice = '';

  /// Основной перевод — модуль, открываемый по умолчанию.
  String defaultModule = 'russyn';

  /// id голосового пакета для двухбуквенного языка ('ru','en'); '' — нет.
  String voiceFor(String lang) {
    for (final e in neuralVoices.split(',')) {
      final i = e.indexOf(':');
      if (i > 0 && e.substring(0, i) == lang) return e.substring(i + 1);
    }
    return '';
  }

  /// Записать выбор голоса для языка ('' — снять выбор).
  void setVoiceFor(String lang, String id) {
    final m = <String, String>{};
    for (final e in neuralVoices.split(',')) {
      final i = e.indexOf(':');
      if (i > 0) m[e.substring(0, i)] = e.substring(i + 1);
    }
    if (id.isEmpty) {
      m.remove(lang);
    } else {
      m[lang] = id;
    }
    neuralVoices = m.entries.map((e) => '${e.key}:${e.value}').join(',');
  }

  /// Признак завершённой загрузки: до неё сохранять нельзя —
  /// иначе дефолты затёрли бы сохранённые значения.
  bool _loaded = false;

  /// Загрузить настройки из UserData (kind=mark, module='settings',
  /// book='SET', context — JSON со всеми полями).
  Future<void> load() async {
    try {
      final all = await bridgeEntriesList('mark');
      final e = all
          .where((e) => e.module == 'settings' && e.book == 'SET')
          .firstOrNull;
      if (e != null && e.context.isNotEmpty) {
        final j = jsonDecode(e.context) as Map<String, dynamic>;
        theme = AppTheme.values[j['theme'] as int? ?? 0];
        autoNight = j['autoNight'] as bool? ?? false;
        nightStart = j['nightStart'] as int? ?? 22 * 60;
        nightEnd = j['nightEnd'] as int? ?? 7 * 60;
        nightTheme = AppTheme.values[j['nightTheme'] as int? ?? 1];
        fontScale = (j['fontScale'] as num? ?? 1.0).toDouble();
        fontWeightStep = (j['fontWeightStep'] as num? ?? 0)
            .toInt()
            .clamp(0, kFontWeightSteps.length - 1);
        footScale = (j['footScale'] as num? ?? 1.0).toDouble();
        xrefScale = (j['xrefScale'] as num? ?? 1.0).toDouble();
        layoutMode = LayoutMode.values[j['layoutMode'] as int? ?? 0];
        columnWidth = ColumnWidth.values[j['columnWidth'] as int? ?? 1];
        readerMode = ReaderMode.values[j['readerMode'] as int? ?? 0];
        layerFootnotes = j['layerFootnotes'] as bool? ?? true;
        layerXrefs = j['layerXrefs'] as bool? ?? true;
        layerStrongs = j['layerStrongs'] as bool? ?? true;
        readingFont = ReadingFont.values[j['readingFont'] as int? ?? 0];
        bookFullNames = j['bookFullNames'] as bool? ?? false;
        versePickerEnabled = j['versePickerEnabled'] as bool? ?? false;
        activePlan = j['activePlan'] as String? ?? '';
        planStart = j['planStart'] as String? ?? '';
        xrefModule = j['xrefModule'] as String? ?? '';
        compareModules = j['compareModules'] as String? ?? '';
        interleavedModules = j['interleavedModules'] as String? ?? '';
        lang = j['lang'] as String? ?? 'ru';
        bookNames = j['bookNames'] as String? ?? 'synodal';
        voiceEngine = j['voiceEngine'] as String? ?? 'auto';
        neuralVoices = j['neuralVoices'] as String? ?? '';
        voiceRate = (j['voiceRate'] as num? ?? 1.0).toDouble();
        voiceWords = j['voiceWords'] as bool? ?? false;
        voiceAccent = j['voiceAccent'] as bool? ?? true;
        systemEngine = j['systemEngine'] as String? ?? '';
        systemVoice = j['systemVoice'] as String? ?? '';
        defaultModule = j['defaultModule'] as String? ?? 'russyn';
      }
    } catch (_) {
      // Битый JSON/ошибка моста — работаем на значениях по умолчанию.
    }
    _loaded = true;
    _syncNightTimer();
    notifyListeners();
  }

  /// Записать текущее состояние одной записью UserData.
  Future<void> _save() async {
    final j = jsonEncode({
      'theme': theme.index,
      'autoNight': autoNight,
      'nightStart': nightStart,
      'nightEnd': nightEnd,
      'nightTheme': nightTheme.index,
      'fontScale': fontScale,
      'fontWeightStep': fontWeightStep,
      'footScale': footScale,
      'xrefScale': xrefScale,
      'layoutMode': layoutMode.index,
      'columnWidth': columnWidth.index,
      'readerMode': readerMode.index,
      'layerFootnotes': layerFootnotes,
      'layerXrefs': layerXrefs,
      'layerStrongs': layerStrongs,
      'readingFont': readingFont.index,
      'bookFullNames': bookFullNames,
      'versePickerEnabled': versePickerEnabled,
      'activePlan': activePlan,
      'planStart': planStart,
      'xrefModule': xrefModule,
      'compareModules': compareModules,
      'interleavedModules': interleavedModules,
      'lang': lang,
      'bookNames': bookNames,
      'voiceEngine': voiceEngine,
      'neuralVoices': neuralVoices,
      'voiceRate': voiceRate,
      'voiceWords': voiceWords,
      'voiceAccent': voiceAccent,
      'systemEngine': systemEngine,
      'systemVoice': systemVoice,
      'defaultModule': defaultModule,
    });
    try {
      final all = await bridgeEntriesList('mark');
      for (final e in all.where(
        (e) => e.module == 'settings' && e.book == 'SET',
      )) {
        await bridgeEntryRemove(e.id);
      }
      await bridgeEntryAdd(
        kind: 'mark',
        module: 'settings',
        book: 'SET',
        chapter: 0,
        verse: 0,
        text: 'settings',
        context: j,
      );
    } catch (_) {
      // Не сохранилось — следующий запуск вернёт старые значения.
    }
  }

  void update(void Function() fn) {
    fn();
    _syncNightTimer();
    notifyListeners();
    if (_loaded) _save();
  }

  /// Изменение без записи — живой предпросмотр (pinch-zoom шлёт
  /// события каждый кадр; сотни записей в userdata.db за один жест
  /// не нужны). Сохранение по концу жеста — через [save].
  void preview(void Function() fn) {
    fn();
    notifyListeners();
  }

  /// Записать текущие настройки (как в конце [update]).
  void save() {
    if (_loaded) _save();
  }

  /// Модули для экрана «стих во всех переводах»: явный список или,
  /// если не задан, все установленные.
  List<String> get compareList => compareModules.isEmpty
      ? installedModules.keys.toList()
      : compareModules.split(',').where(installedModules.containsKey).toList();

  /// Модуль для текстов в карточках параллельных мест.
  String get xrefModuleOrMain =>
      xrefModule.isEmpty ? mainModuleId() : xrefModule;

  /// Модули строчного сравнения в порядке показа (только
  /// установленные; '' — пустой список, решение у читалки).
  List<String> get interleavedList => interleavedModules
      .split(',')
      .where(installedModules.containsKey)
      .toList();
}

/// Единственный экземпляр настроек.
final Settings settings = Settings();

/// Прогресс чтения: «глава прочитана» и «последняя позиция».
class ReadProgress extends ChangeNotifier {
  /// 'GEN:1' — прочитанные главы.
  final Set<String> read = {};

  /// 'GEN:1' — где остановился (маркер «продолжить»).
  String? lastPosition;

  /// 'GEN:1' -> последний выбранный стих (для автоскролла при возврате).
  final Map<String, int> lastVerse = {};

  bool isRead(String bookCode, int chapter) =>
      read.contains('$bookCode:$chapter');

  int readCount(String bookCode) =>
      read.where((k) => k.startsWith('$bookCode:')).length;

  /// Загрузить сохранённый прогресс (один раз при старте приложения).
  Future<void> load() async {
    final raw = await bridgeProgressLoad();
    if (raw == null) return;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    read
      ..clear()
      ..addAll((j['read'] as List? ?? []).cast<String>());
    lastPosition = j['last_position'] as String?;
    lastVerse
      ..clear()
      ..addAll(
        (j['last_verse'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(k, (v as num).toInt()),
        ),
      );
    notifyListeners();
  }

  void markRead(String bookCode, int chapter) {
    read.add('$bookCode:$chapter');
    // Сохранение — в фоне: UI не ждёт запись в SQLite.
    bridgeProgressMarkRead(bookCode, chapter);
    notifyListeners();
  }

  void setPosition(String bookCode, int chapter) {
    lastPosition = '$bookCode:$chapter';
    bridgeProgressSetPosition(
      bookCode,
      chapter,
      lastVerse['$bookCode:$chapter'] ?? 0,
    );
    notifyListeners();
  }

  void setVerse(String bookCode, int chapter, int verse) {
    lastVerse['$bookCode:$chapter'] = verse;
    bridgeProgressSetVerse(bookCode, chapter, verse);
    notifyListeners();
  }

  void reset() {
    read.clear();
    lastPosition = null;
    lastVerse.clear();
    bridgeProgressReset();
    notifyListeners();
  }
}

final ReadProgress progress = ReadProgress();

/// Хранимый формат заметки: «заголовок\x1Fтекст»; без \x1F — всё тело
/// (совместимо со старыми записями без заголовка).
(String title, String body) splitNote(String s) {
  final i = s.indexOf('\x1F');
  if (i < 0) return ('', s);
  return (s.substring(0, i), s.substring(i + 1));
}

/// Собрать текст записи из заголовка и тела.
String joinNote(String title, String body) =>
    title.isEmpty ? body : '$title\x1F$body';

/// Свободная заметка на странице «Записи».
class NoteItem {
  final String id;
  String text;

  /// Заголовок заметки (может быть пустым).
  String title;

  /// Якорь стиха для заметок, созданных из текста ('' — свободная).
  final String module, book;
  final int chapter, verse;
  final DateTime created;

  NoteItem(
    this.id,
    this.text,
    this.created, {
    this.title = '',
    this.module = '',
    this.book = '',
    this.chapter = 0,
    this.verse = 0,
  });

  /// Есть ли привязка к месту Писания.
  bool get anchored => book.isNotEmpty;

  /// «Бт 1:24» — короткая ссылка для подзаголовка.
  String get ref => anchored ? '$book $chapter:$verse' : '';
}

/// Заметки пользователя: свободный текст, записи UserData kind='note'
/// (userdata.db / localStorage на web). К стихам не привязаны —
/// заметки к стиху живут в листе стиха (notes_sheet).
class Notes extends ChangeNotifier {
  final List<NoteItem> items = [];
  bool _loaded = false;

  Future<void> load() async {
    final all = await bridgeEntriesList('note');
    items
      ..clear()
      ..addAll(
        all.map((e) {
          final (t, b) = splitNote(e.text);
          return NoteItem(
            e.id,
            b,
            DateTime.fromMillisecondsSinceEpoch(e.created),
            title: t,
            module: e.module,
            book: e.book,
            chapter: e.chapter,
            verse: e.verse,
          );
        }),
      );
    // Группы по переводу (в.12, этап А): свободные заметки
    // (module '') впереди, затем по id модуля, внутри — по дате.
    items.sort(
      (a, b) => a.module == b.module
          ? b.created.compareTo(a.created)
          : a.module.compareTo(b.module),
    );
    _loaded = true;
    notifyListeners();
  }

  Future<void> add(String title, String text) async {
    final b = text.trim();
    final t = title.trim();
    if (b.isEmpty && t.isEmpty) return;
    if (!_loaded) await load();
    final id = await bridgeEntryAdd(
      kind: 'note',
      module: '',
      book: '',
      chapter: 0,
      verse: 0,
      text: joinNote(t, b),
      context: '',
    );
    // Мост может вернуть null (стаб/офлайн) — тогда локальный id.
    items.insert(
      0,
      NoteItem(
        id ?? 'local-${DateTime.now().microsecondsSinceEpoch}',
        b,
        DateTime.now(),
        title: t,
      ),
    );
    notifyListeners();
  }

  /// Изменить заголовок/текст заметки (заголовок хранится в text
  /// записи — bridgeEntryUpdate обновляет только text).
  Future<void> edit(NoteItem n, String title, String text) async {
    final b = text.trim();
    final t = title.trim();
    n.title = t;
    n.text = b;
    await bridgeEntryUpdate(n.id, joinNote(t, b));
    notifyListeners();
  }

  Future<void> remove(NoteItem n) async {
    items.remove(n);
    await bridgeEntryRemove(n.id);
    notifyListeners();
  }
}

final Notes notes = Notes();

/// Сквозная история навигации — записи kind=mark с текстом
/// 'hist*' в UserData (userdata.db / localStorage на web).
/// 'hist' — глава/стих, 'hist:dict' — словарь Стронга,
/// 'hist:search' — поисковый запрос. Без ограничения по времени.
class ReadingHistory extends ChangeNotifier {
  /// Отсортировано по убыванию `updated` — свежие сверху.
  final List<UserEntry> items = [];
  bool _loaded = false;

  Future<void> load() async {
    final all = await bridgeEntriesList('mark');
    items
      ..clear()
      ..addAll(all.where((e) => e.text.startsWith('hist')));
    items.sort((a, b) => b.updated.compareTo(a.updated));
    _loaded = true;
    notifyListeners();
  }

  /// Удалить старые записи по [same] и вставить свежую наверх.
  Future<void> _push({
    required String module,
    required String book,
    required int chapter,
    required int verse,
    required String text,
    required String context,
    required bool Function(UserEntry) same,
  }) async {
    if (!_loaded) await load();
    for (final e in items.where(same).toList()) {
      await bridgeEntryRemove(e.id);
      items.remove(e);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await bridgeEntryAdd(
      kind: 'mark',
      module: module,
      book: book,
      chapter: chapter,
      verse: verse,
      text: text,
      context: context,
    );
    items.insert(
      0,
      UserEntry(
        id: id ?? 'local-$now',
        module: module,
        kind: 'mark',
        book: book,
        chapter: chapter,
        verse: verse,
        text: text,
        context: context,
        created: now,
        updated: now,
      ),
    );
    notifyListeners();
  }

  /// Отметить посещение главы: одна запись на (модуль, книга, глава)
  /// со свежей меткой и последним открытым стихом.
  Future<void> touch(
    String module,
    String book,
    int chapter, {
    int verse = 0,
  }) => _push(
    module: module,
    book: book,
    chapter: chapter,
    verse: verse,
    text: 'hist',
    context: '',
    same: (e) =>
        e.text == 'hist' &&
        e.module == module &&
        e.book == book &&
        e.chapter == chapter,
  );

  /// Отметить обращение к словарю Стронга (номер + слово в context).
  /// book='LEX': якорь UserData требует ровно 3 символа BookCode.
  Future<void> touchDict(String strong, String word) => _push(
    module: 'lexicon',
    book: 'LEX',
    chapter: 0,
    verse: 0,
    text: 'hist:dict',
    context: '$strong|$word',
    same: (e) => e.text == 'hist:dict' && e.context.split('|').first == strong,
  );

  /// Отметить поисковый запрос (сам запрос в context).
  Future<void> touchSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) return Future.value();
    return _push(
      module: 'search',
      book: 'SRH',
      chapter: 0,
      verse: 0,
      text: 'hist:search',
      context: q,
      same: (e) => e.text == 'hist:search' && e.context == q,
    );
  }
}

final ReadingHistory history = ReadingHistory();
