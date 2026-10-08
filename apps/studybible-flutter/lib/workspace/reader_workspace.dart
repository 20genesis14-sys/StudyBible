/// Рабочее место чтения (ADR 0019): обобщённые позиции, стек
/// переходов «назад/вперёд», персистентность между запусками.
///
/// Синглтон уровня [settings]/[progress]/[history] — без
/// Provider/get_it: перейти на DI позже можно без смены API
/// (объект не знает о виджетах и не знает о них зависимостей).
///
/// Стек — короткая память переходов (до [_maxEntries]); полный
/// журнал посещений без лимита ведёт [ReadingHistory] отдельно.
/// Свайпы, переходы по ссылкам и смена перевода на месте — переходы;
/// прокрутка внутри главы и смена режимов/слоёв — нет (обновляют
/// снимок текущей записи через [updateSnapshot]).
///
/// Персистентность — та же запись UserData, что у настроек:
/// kind='mark', module='settings', book='WS', context — JSON.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../native_bridge_stub.dart'
    if (dart.library.io) '../native_bridge_io.dart'
    if (dart.library.html) '../native_bridge_web.dart';

/// Обобщённая позиция: (kind, ref). 'verse' — стих Библии;
/// 'dict' — статья словаря (book=''), дальше по модели документов.
/// Вид открыт, расширяется новыми kind без смены схемы.
@immutable
class Location {
  /// 'verse' | 'dict' | 'commentary' | 'apparatus' | ...
  final String kind;

  /// Модуль, к которому относится позиция.
  final String moduleId;
  final String book;
  final int chapter;
  final int verse;

  /// Снимок состояния панели на момент перехода (режим сравнения,
  /// второй перевод и т.п.). Открытый словарь — схема растёт
  /// с панелями ADR 0019.
  final Map<String, Object?> pane;

  const Location({
    this.kind = 'verse',
    required this.moduleId,
    this.book = '',
    this.chapter = 0,
    this.verse = 0,
    this.pane = const {},
  });

  const Location.verse({
    required String moduleId,
    required String book,
    required int chapter,
    int verse = 0,
    Map<String, Object?> pane = const {},
  }) : this(
         moduleId: moduleId,
         book: book,
         chapter: chapter,
         verse: verse,
         pane: pane,
       );

  /// Та же позиция? Дубликат в стек не пишется (ADR 0019):
  /// повторный переход туда же — не переход.
  bool samePlace(Location o) =>
      kind == o.kind &&
      moduleId == o.moduleId &&
      book == o.book &&
      chapter == o.chapter &&
      verse == o.verse &&
      pane['screen'] == o.pane['screen'];

  Location copyWith({Map<String, Object?>? pane}) => Location(
    kind: kind,
    moduleId: moduleId,
    book: book,
    chapter: chapter,
    verse: verse,
    pane: pane ?? this.pane,
  );

  Map<String, Object?> toJson() => {
    'kind': kind,
    'module': moduleId,
    'book': book,
    'ch': chapter,
    'v': verse,
    if (pane.isNotEmpty) 'pane': pane,
  };

  factory Location.fromJson(Map<String, dynamic> j) => Location(
    kind: j['kind'] as String? ?? 'verse',
    moduleId: j['module'] as String? ?? '',
    book: j['book'] as String? ?? '',
    chapter: j['ch'] as int? ?? 0,
    verse: j['v'] as int? ?? 0,
    pane:
        (j['pane'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v),
        ) ??
        const {},
  );

  @override
  String toString() =>
      kind == 'verse' ? '$moduleId:$book $chapter:$verse' : '$kind:$moduleId';
}

/// Рабочее место: стек позиций с курсором «назад/вперёд».
class ReaderWorkspace extends ChangeNotifier {
  /// Верхняя граница короткой памяти переходов (ADR 0019).
  static const int _maxEntries = 250;

  final List<Location> _stack = [];
  int _index = -1;
  bool _loaded = false;

  /// Текущая позиция курсора (null — рабочее место ещё не открыто).
  Location? get current => _index >= 0 ? _stack[_index] : null;

  bool get canBack => _index > 0;
  bool get canForward => _index >= 0 && _index < _stack.length - 1;

  /// Глубина стека для отладки/будущей истории-панели.
  int get depth => _stack.length;
  int get index => _index;

  /// Записать переход на позицию [loc]. Отсекает «вперёд»-хвост,
  /// не пишет дубликат текущей позиции, держит лимит в 250.
  void go(Location loc) {
    if (current?.samePlace(loc) == true) {
      // Та же позиция — но снимок панели мог измениться (смена
      // режима сравнения на месте). Обновляем, не записывая переход.
      _stack[_index] = loc;
      _save();
      notifyListeners();
      return;
    }
    if (canForward) _stack.removeRange(_index + 1, _stack.length);
    _stack.add(loc);
    _index = _stack.length - 1;
    if (_stack.length > _maxEntries) {
      _stack.removeRange(0, _stack.length - _maxEntries);
      _index = _stack.length - 1;
    }
    _save();
    notifyListeners();
  }

  /// Шаг назад: позиция, к которой вернулись (null — стек исчерпан,
  /// дальше только «домой» — решает вызывающая сторона).
  Location? back() {
    if (!canBack) return null;
    _index--;
    _save();
    notifyListeners();
    return current;
  }

  /// Шаг вперёд после [back].
  Location? forward() {
    if (!canForward) return null;
    _index++;
    _save();
    notifyListeners();
    return current;
  }

  /// Обновить снимок панели текущей записи без перехода
  /// (смена слоёв/режимов — не навигация, ADR 0019).
  void updateSnapshot(Map<String, Object?> pane) {
    if (_index < 0) return;
    _stack[_index] = _stack[_index].copyWith(pane: pane);
    _save();
  }

  /// Поднять стек между запусками (фон — старт всегда на «Доме»).
  Future<void> load() async {
    try {
      final all = await bridgeEntriesList('mark');
      final e = all
          .where((e) => e.module == 'settings' && e.book == 'WS')
          .firstOrNull;
      if (e != null && e.context.isNotEmpty) {
        final j = jsonDecode(e.context) as Map<String, dynamic>;
        final list = (j['stack'] as List? ?? [])
            .whereType<Map>()
            .map((m) => Location.fromJson(m.cast<String, dynamic>()))
            .where((l) => l.moduleId.isNotEmpty)
            .toList();
        _stack
          ..clear()
          ..addAll(list.length > _maxEntries
              ? list.sublist(list.length - _maxEntries)
              : list);
        _index = (j['index'] as int? ?? _stack.length - 1).clamp(
          -1,
          _stack.length - 1,
        );
      }
    } catch (_) {
      // Битая запись — начинаем с пустого стека.
    }
    _loaded = true;
  }

  /// Одна запись UserData, как у настроек. Пустой стек не пишем.
  Future<void> _save() async {
    if (!_loaded) return;
    try {
      final all = await bridgeEntriesList('mark');
      for (final e in all.where(
        (e) => e.module == 'settings' && e.book == 'WS',
      )) {
        await bridgeEntryRemove(e.id);
      }
      if (_stack.isEmpty) return;
      await bridgeEntryAdd(
        kind: 'mark',
        module: 'settings',
        book: 'WS',
        chapter: 0,
        verse: 0,
        text: 'workspace',
        context: jsonEncode({
          'v': 1,
          'index': _index,
          'stack': _stack.map((l) => l.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Не сохранилось — при следующем запуске стек вернётся старым.
    }
  }
}

/// Единственное рабочее место приложения (одно окно, одна лента чтения).
final workspace = ReaderWorkspace();
