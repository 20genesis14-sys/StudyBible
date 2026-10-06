/// Выбор голосового бэкенда по настройкам и языку главы (ADR 0017):
/// `auto` — нейроголос, если установлен для языка, иначе системный;
/// `neural` — только нейро (нет пакета — понятная ошибка);
/// `system` — системный синтезатор (web — всегда он).
library;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../l10n.dart';
import '../state.dart';
import 'voice_backend.dart';
import 'voice_neural.dart';
import 'voice_pack.dart';
import 'voice_registry.dart';
import 'voice_system.dart';

/// Подобрать и подготовить бэкенд. При отказе — error для показа
/// пользователю; в режиме `auto` нейро-ошибки молча откатываются
/// на системный движок.
Future<({VoiceBackend? backend, String? error})> pickVoiceBackend(
  String language,
) async {
  final engine = settings.voiceEngine;
  if (!kIsWeb && engine != 'system') {
    final pack = voiceForLanguage(
      scanVoices(),
      language,
      settings.neuralVoices,
    );
    if (pack != null) {
      final b = NeuralVoiceBackend(pack);
      try {
        await b.prepare(language: language, rate: settings.voiceRate);
        return (backend: b, error: null);
      } catch (e) {
        b.dispose();
        if (engine == 'neural') {
          return (
            backend: null,
            error: tr(
              'Нейросинтез не запустился ($e). Проверьте голосовой пакет',
              'Neural engine failed ($e). Check the voice pack',
            ),
          );
        }
        // auto — молча откатываемся на системный.
      }
    } else if (engine == 'neural') {
      return (
        backend: null,
        error: tr(
          'Нет голосового пакета для $language — импортируйте его: Настройки → Чтение вслух',
          'No voice pack for $language — import one: Settings → Read aloud',
        ),
      );
    }
  }
  final b = SystemVoiceBackend();
  try {
    await b.prepare(language: language, rate: settings.voiceRate);
    return (backend: b, error: null);
  } catch (_) {
    return (
      backend: null,
      error: tr(
        'Синтез речи недоступен: проверьте TTS-движок и голос языка в настройках Android',
        'Speech synthesis unavailable: check the TTS engine and voice in Android settings',
      ),
    );
  }
}
