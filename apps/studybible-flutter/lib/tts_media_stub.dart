/// Заглушка медиа-сессии чтения вслух (web и платформы без
/// audio_service): ничего не делает, интерфейс тот же, что у
/// tts_media_io.dart.
library;

/// Колбэки кнопок медиа-уведомления/гарнитуры.
typedef TtsCallback = void Function();

class ReadAloudSession {
  const ReadAloudSession();

  void setCallbacks({
    required TtsCallback onPause,
    required TtsCallback onResume,
    required TtsCallback onPrev,
    required TtsCallback onNext,
    required TtsCallback onStop,
  }) {}

  /// Позиция в главе и состояние для уведомления.
  void update({
    required String title,
    required String subtitle,
    required int index,
    required int total,
    required bool playing,
  }) {}

  /// Сеанс закрыт: убрать уведомление/освободить фокус.
  void clear() {}

  /// Разрешение на уведомления (Android 13+); здесь — no-op.
  Future<void> ensurePermission() async {}
}

const readAloud = ReadAloudSession();

Future<void> initReadAloud() async {}
