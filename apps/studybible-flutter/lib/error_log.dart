/// Журнал ошибок приложения (BUGS 18.10.2026, «молчаливые ошибки»).
///
/// Ранее ошибки проглатывались в `catch (_) {}`: загрузка и сохранение
/// настроек, ленивые шрифты, фоллбэки модулей молча работали на
/// значениях по умолчанию, и о проблеме на реальном устройстве
/// разработчик узнавал только от пользователя. Теперь точки провала
/// пишут в этот кольцевой буфер (последние [ErrorLog.maxRecords]
/// записей), а раздел «Настройки» → «Диагностика» показывает записи
/// и позволяет скопировать весь журнал в буфер обмена.
///
/// Только Flutter SDK, без внешних зависимостей.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Одна запись журнала: время, контекст (место в коде вида
/// 'settings.load'), ошибка и её стек (если был).
typedef ErrorLogRecord = ({
  DateTime time,
  String context,
  Object? error,
  StackTrace? stack,
});

/// Кольцевой буфер ошибок: держит самые свежие
/// [ErrorLog.maxRecords] записей, старые вытесняются.
class ErrorLog extends ChangeNotifier {
  /// Максимум записей в буфере.
  static const int maxRecords = 200;

  final ListQueue<ErrorLogRecord> _records = ListQueue();

  /// Записать ошибку с местом возникновения [context] (например,
  /// 'settings.load'); [stack] не обязателен.
  void logError(String context, Object error, [StackTrace? stack]) {
    _records.addLast((
      time: DateTime.now(),
      context: context,
      error: error,
      stack: stack,
    ));
    while (_records.length > maxRecords) {
      _records.removeFirst();
    }
    notifyListeners();
  }

  /// Неизменяемая копия записей, старые впереди (для показа и
  /// копирования).
  List<ErrorLogRecord> get records => List.unmodifiable(_records);

  /// Сколько записей сейчас в буфере.
  int get count => _records.length;

  /// Очистить журнал.
  void clear() {
    if (_records.isEmpty) return;
    _records.clear();
    notifyListeners();
  }
}

/// Единственный экземпляр журнала ошибок.
final ErrorLog errorLog = ErrorLog();
