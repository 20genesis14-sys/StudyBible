import 'package:flutter/gestures.dart' show GestureRecognizer;
import 'package:flutter/widgets.dart';

/// Строка главы в кэше: виджет и созданные при её сборке
/// распознаватели жестов. Распознаватели принадлежат записи —
/// утилизируются вместе с ней (ADR 0030).
class CachedLine {
  CachedLine(this.widget, this.recognizers);

  final Widget widget;
  final List<GestureRecognizer> recognizers;
}

/// Отключение кэша строки: компиляционный флаг для замеров «до/после»
/// (ADR 0030, шаг 5). Запуск:
/// `flutter test --dart-define=STUDYBIBLE_NO_RENDER_CACHE=true` —
/// все строки строятся мимо кэша, поведение как до ADR 0030.
const bool kRenderCacheDisabled = bool.fromEnvironment(
  'STUDYBIBLE_NO_RENDER_CACHE',
);

/// Кэш построенных строк главы (ADR 0030).
///
/// Спаны главы пересоздавались на каждый `setState` экрана — тик слова
/// при чтении вслух стоил пересборки тысяч спанов. Строка кэшируется по
/// ключу (`L:стих`, `B:блок`, `I:стих`, `S:модуль:стих`…); динамические
/// строки (выбранный/читаемый стих) строятся мимо кэша, пока активны.
///
/// Жизненный цикл распознавателей: распознаватели, отданные записи через
/// [put], живут до выселения записи; выселение и очистка откладывают
/// dispose на конец кадра — виджет мог ещё участвовать в прошлом кадре.
/// [dispose] утилизирует всё сразу (дерево экрана разобрано).
class ChapterLineCache {
  final Map<String, CachedLine> _lines = {};
  final List<CachedLine> _retired = [];
  bool _retireScheduled = false;

  int _hits = 0;
  int _misses = 0;

  /// Суммарные попадания по всем экземплярам кэша (диагностика/замеры:
  /// экземпляр кэша — частное поле экрана, наружу смотрит статистика
  /// класса).
  static int totalHits = 0;
  static int totalMisses = 0;

  /// Обнулить суммарные счётчики (замеры).
  static void resetTotalStats() {
    totalHits = 0;
    totalMisses = 0;
  }

  /// Число живых записей (диагностика/тесты).
  int get length => _lines.length;

  /// Попадания в кэш (диагностика/замеры, ADR 0030 шаг 5).
  int get hits => _hits;

  /// Промахи при обращении по ключу (диагностика/замеры).
  int get misses => _misses;

  /// Обнулить счётчики попаданий (замеры).
  void resetStats() {
    _hits = 0;
    _misses = 0;
  }

  /// Виджет записи или null (промах).
  Widget? get(String key) {
    final line = _lines[key];
    if (line != null) {
      _hits++;
      totalHits++;
    } else {
      _misses++;
      totalMisses++;
    }
    return line?.widget;
  }

  /// Положить строку вместе с её распознавателями (владение переходит
  /// кэшу; прежняя запись с тем же ключом выселяется).
  void put(String key, Widget widget, List<GestureRecognizer> recognizers) {
    final old = _lines[key];
    if (old != null) _retired.add(old);
    _lines[key] = CachedLine(widget, List.of(recognizers));
    _scheduleRetire();
  }

  /// Выселить запись (стих стал динамическим, запись устарела).
  void evict(String key) {
    final old = _lines.remove(key);
    if (old != null) {
      _retired.add(old);
      _scheduleRetire();
    }
  }

  /// Очистить весь кэш (смена сигнатуры рендера); dispose — в конце
  /// кадра, когда выселенные виджеты гарантированно заменены.
  void clear() {
    if (_lines.isEmpty) return;
    _retired.addAll(_lines.values);
    _lines.clear();
    _scheduleRetire();
  }

  /// Утилизировать всё немедленно — при закрытии экрана.
  void dispose() {
    for (final line in _lines.values) {
      for (final r in line.recognizers) {
        r.dispose();
      }
    }
    _lines.clear();
    _flushRetired();
  }

  void _scheduleRetire() {
    if (_retireScheduled || _retired.isEmpty) return;
    _retireScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushRetired());
  }

  void _flushRetired() {
    _retireScheduled = false;
    for (final line in _retired) {
      for (final r in line.recognizers) {
        r.dispose();
      }
    }
    _retired.clear();
  }
}
