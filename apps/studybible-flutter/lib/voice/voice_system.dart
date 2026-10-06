/// Бэкенд `system`: системный синтезатор через flutter_tts.
/// Точной паузы внутри фразы нет (Android), зато есть точные
/// пословные события (progressHandler — Android/iOS/macOS/web).
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_tts/flutter_tts.dart';

import 'voice_backend.dart';

class SystemVoiceBackend extends VoiceBackend {
  FlutterTts? _tts;
  String _language = 'ru-RU';
  double _rate = 1.0;
  final _wordsCtl = StreamController<WordMark>.broadcast();

  @override
  String get id => 'system';

  /// На Android без объявления TTS_SERVICE в queries и без
  /// движка синтез молча не работает; голос языка может быть
  /// не скачан — оба случая проверяем явно в prepare.
  @override
  Future<void> prepare({
    required String language,
    required double rate,
  }) async {
    final tts = _tts ??= FlutterTts();
    if (!kIsWeb) {
      final engines = await tts.getEngines;
      if (engines is List && engines.isEmpty) {
        throw StateError('no tts engine');
      }
    }
    final langOk = await tts.isLanguageAvailable(language);
    if (langOk != true) {
      throw StateError('no voice for $language');
    }
    _language = language;
    _rate = rate;
    await tts.setLanguage(language);
    // rate — множитель поверх привычных 0.45 (речь и так медленнее).
    await tts.setSpeechRate((0.45 * rate).clamp(0.1, 1.0));
    await tts.setVolume(1.0);
    await tts.setPitch(1.0);
    await tts.awaitSpeakCompletion(true);
    tts.setProgressHandler((text, start, end, word) {
      if (!_wordsCtl.isClosed) _wordsCtl.add(WordMark(start, end, word));
    });
  }

  String get language => _language;
  double get rate => _rate;

  /// speak() с awaitSpeakCompletion завершается по концу фразы;
  /// 0 — движок отклонил фразу (сервис повторяет однажды).
  @override
  Future<bool> speak(String text) async {
    final tts = _tts;
    if (tts == null) return false;
    final r = await tts.speak(text);
    return r != 0;
  }

  @override
  Future<void> stop() async => _tts?.stop();

  @override
  Stream<WordMark>? get words => _wordsCtl.stream;

  @override
  void dispose() {
    _tts?.stop();
    // Контроллер не закрываем: бэкенд может быть выбран повторно,
    // dispose зовётся только со сменой/смертью сервиса.
  }
}
