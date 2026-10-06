/// Настройки и пользовательский прогресс.
///
/// Настройки пока в памяти. Прогресс на нативных платформах
/// персистируется через Rust-мост в store::UserData (userdata.db
/// в каталоге данных); на web — только в памяти.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

// Прогресс через мост; на web — заглушка без сохранения.
import 'native_bridge_stub.dart'
    if (dart.library.io) 'native_bridge_io.dart'
    if (dart.library.html) 'native_bridge_web.dart';
import 'native_bridge.dart' show UserEntry;
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

  /// Масштаб шрифта: 0.8 – 1.6, шаг настройки.
  double fontScale = 1.0;

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

  /// Язык интерфейса: 'ru' | 'en'.
  String lang = 'ru';

  /// Основной перевод — модуль, открываемый по умолчанию.
  String defaultModule = 'russyn';

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
        fontScale = (j['fontScale'] as num? ?? 1.0).toDouble();
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
        lang = j['lang'] as String? ?? 'ru';
        defaultModule = j['defaultModule'] as String? ?? 'russyn';
      }
    } catch (_) {
      // Битый JSON/ошибка моста — работаем на значениях по умолчанию.
    }
    _loaded = true;
    notifyListeners();
  }

  /// Записать текущее состояние одной записью UserData.
  Future<void> _save() async {
    final j = jsonEncode({
      'theme': theme.index,
      'fontScale': fontScale,
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
      'lang': lang,
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
    notifyListeners();
    if (_loaded) _save();
  }
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

/// Свободная заметка на странице «График чтения».
class NoteItem {
  final String id;
  String text;
  final DateTime created;
  NoteItem(this.id, this.text, this.created);
}

/// Заметки пользователя. Пока в памяти; персистентность через
/// store::UserData (kind=note) — следующий шаг моста.
class Notes extends ChangeNotifier {
  final List<NoteItem> items = [];

  void add(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    items.insert(
      0,
      NoteItem('${DateTime.now().microsecondsSinceEpoch}', t, DateTime.now()),
    );
    notifyListeners();
  }

  void remove(NoteItem n) {
    items.remove(n);
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
