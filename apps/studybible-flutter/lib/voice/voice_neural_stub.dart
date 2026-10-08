/// Заглушка нейробэкенда для web: сообщает «нет голоса» —
/// подбор бэкенда откатится на системный движок.
library;

import 'voice_backend.dart';
import 'voice_pack.dart';

/// sherpa_onnx вырезан из сборки (ADR 0017 «Статус 12.10.2026»):
/// pickVoiceBackend не тратит время на скан пакетов и сразу
/// выбирает системный движок.
const bool kNeuralAvailable = false;

class NeuralVoiceBackend extends VoiceBackend {
  NeuralVoiceBackend(this.pack);

  final VoicePack? pack;

  @override
  String get id => 'neural';

  @override
  Future<void> prepare({required String language, required double rate}) =>
      throw StateError('no neural tts on web');

  @override
  Future<bool> speak(String text) async => false;

  @override
  Future<void> stop() async {}
}
