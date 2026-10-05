/// Медиа-сессия чтения вслух: на Android/iOS/macOS — уведомление с
/// кнопками управления и audio focus (audio_service), на остальных
/// платформах — no-op.
library;

export 'tts_media_stub.dart' if (dart.library.io) 'tts_media_io.dart';
