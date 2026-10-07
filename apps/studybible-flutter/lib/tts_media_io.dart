/// Медиа-сессия чтения вслух через audio_service (Android/iOS/macOS):
/// системное уведомление с кнопками ‹/пауза/›/стоп, media button и
/// audio focus — ОС видит, что звук играется. На Windows/Linux —
/// no-op, как заглушка.
library;

import 'dart:io' show Platform;

import 'l10n.dart';

import 'package:audio_service/audio_service.dart';
import 'package:permission_handler/permission_handler.dart';

typedef TtsCallback = void Function();

class _Handler extends BaseAudioHandler {
  TtsCallback? onPauseCb, onResumeCb, onPrevCb, onNextCb, onStopCb;

  /// Стоп инициирован нами (clear) — колбэк экрану не нужен.
  bool selfStop = false;

  @override
  Future<void> play() async => onResumeCb?.call();

  @override
  Future<void> pause() async => onPauseCb?.call();

  @override
  Future<void> skipToNext() async => onNextCb?.call();

  @override
  Future<void> skipToPrevious() async => onPrevCb?.call();

  /// Приложение смахнули из «недавних» — чтение останавливаем,
  /// иначе уведомление и состояние плеера остаются висеть.
  @override
  Future<void> onTaskRemoved() async {
    onStopCb?.call();
    await super.onTaskRemoved();
  }

  @override
  Future<void> stop() async {
    if (!selfStop) {
      // Крестик в уведомлении/системный стоп — отдаём наверх,
      // экран сам вызовет clear() → реальный stop.
      onStopCb?.call();
      return;
    }
    playbackState.add(
      playbackState.value.copyWith(
        controls: [],
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
    await super.stop();
  }
}

class ReadAloudSession {
  const ReadAloudSession(this._handler);
  final BaseAudioHandler? _handler;

  _Handler? get _impl => _handler is _Handler ? _handler : null;

  void setCallbacks({
    required TtsCallback onPause,
    required TtsCallback onResume,
    required TtsCallback onPrev,
    required TtsCallback onNext,
    required TtsCallback onStop,
  }) {
    final h = _impl;
    if (h == null) return;
    h.onPauseCb = onPause;
    h.onResumeCb = onResume;
    h.onPrevCb = onPrev;
    h.onNextCb = onNext;
    h.onStopCb = onStop;
  }

  /// Позиция в главе и состояние для уведомления: «длительность»
  /// главы считаем в стихах — полоса в уведомлении идёт по стихам.
  void update({
    required String title,
    required String subtitle,
    required int index,
    required int total,
    required bool playing,
  }) {
    final h = _handler;
    if (h == null) return;
    h.mediaItem.add(
      MediaItem(
        id: title,
        album: 'StudyBible',
        title: title,
        artist: subtitle,
        duration: Duration(seconds: total.clamp(1, 1 << 30)),
      ),
    );
    h.playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.playPause,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.stop,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: Duration(seconds: index),
      ),
    );
  }

  /// Сеанс закрыт: снять уведомление и отпустить audio focus.
  void clear() {
    final h = _impl;
    if (h == null) return;
    h.selfStop = true;
    h.stop().whenComplete(() => h.selfStop = false);
  }

  /// Без POST_NOTIFICATIONS на Android 13+ медиа-уведомление
  /// не отображается — спрашиваем при первом запуске чтения.
  Future<void> ensurePermission() async {
    if (!Platform.isAndroid) return;
    final st = await Permission.notification.status;
    if (!st.isGranted) await Permission.notification.request();
  }
}

ReadAloudSession readAloud = ReadAloudSession(null);

/// Запуск фонового аудио-сервиса (из main). Безопасно на любой
/// платформе: где audio_service нет — остаётся заглушка.
Future<void> initReadAloud() async {
  if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
    return;
  }
  final handler = await AudioService.init(
    builder: () => _Handler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.example.studybible.tts',
      androidNotificationChannelName: tr('Чтение вслух', 'Read aloud'),
      // Ongoing нельзя вместе с stopForegroundOnPause=false
      // (assert в audio_service). Уведомление и так остаётся
      // на паузе — мы не снимаем foreground.
      androidStopForegroundOnPause: false,
    ),
  );
  readAloud = ReadAloudSession(handler);
}
