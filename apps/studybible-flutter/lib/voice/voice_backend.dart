/// Голосовой бэкенд чтения вслух (ADR 0017).
///
/// Узкая абстракция над движками речи: `ReaderTtsService` владеет
/// очередью стихов, медиа-сессией и подсветкой; бэкенд только
/// «говорит фразу». Реализации: `system` (flutter_tts), `neural`
/// (sherpa_onnx, VITS/Piper), позже `file` (аудиобиблия + marks).
library;

/// Слово внутри проговариваемой фразы: смещения в символах
/// текста фразы — для пословной подсветки в рендерере.
class WordMark {
  const WordMark(this.start, this.end, this.word);

  /// Индекс первого символа слова в тексте фразы.
  final int start;

  /// Индекс после последнего символа слова.
  final int end;

  /// Само слово (как сообщил движок или оценка).
  final String word;
}

abstract class VoiceBackend {
  /// 'system' | 'neural' | 'file'.
  String get id;

  /// Применить параметры до начала чтения (язык BCP 47, скорость).
  /// Бросает, если бэкенд не готов — ошибка уходит пользователю.
  Future<void> prepare({required String language, required double rate});

  /// Произнести [text]. Future завершается, когда фраза договорила
  /// (или её оборвали). `false` — движок отклонил текст.
  Future<bool> speak(String text);

  /// Точная пауза внутри фразы: аудио встаёт на месте, resume
  /// продолжает с той же точки. `false` — пауза только по стихам
  /// (сервис останавливает фразу и на resume начинает стих с начала).
  bool get canPause => false;

  Future<void> pause() async {}
  Future<void> resume() async {}

  /// Обрыв текущей фразы.
  Future<void> stop();

  /// Предсинтез следующей фразы: нейробэкенд прячет задержку
  /// генерации за временем звучания текущей.
  void prefetch(String text) {}

  /// Пословные метки фразы в символьных смещениях; null —
  /// бэкенд не сообщает позицию (подсветка слов отключена).
  Stream<WordMark>? get words => null;

  void dispose() {}
}
