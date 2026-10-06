/// Smoke-тест настоящего синтеза sherpa_onnx на установленном
/// голосовом пакете. Пропускается, если пакета нет — это ручной
/// инструмент проверки связки движок↔модель, не часть регрессии.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:studybible/voice/voice_pack.dart';
import 'package:studybible/voice/voice_registry_io.dart';
import 'package:studybible/voice/wav.dart';

void main() {
  final root = Platform.isWindows
      ? r'C:\StudyBible-data\voices'
      : '${Platform.environment['HOME']}/StudyBible-data/voices';
  final packs = Directory(root).existsSync() ? scanVoices(root) : <VoicePack>[];
  final pack = packs.where((p) => p.usable && p.language == 'ru').firstOrNull;

  test(
    'нейросинтез: русский голос выдаёт звук',
    () {
      // flutter_tester не раскладывает нативные библии плагина:
      // грузим DLL пакета по абсолютному пути — загруженный модуль
      // по имени файла подменяет резолв зависимостей, иначе System32
      // отдаёт чужой старый onnxruntime.dll.
      const pkg =
          r'C:\Users\Ольга\AppData\Local\Pub\Cache\hosted\pub.dev'
          r'\sherpa_onnx_windows-1.13.8\windows';
      for (final n in [
        'onnxruntime.dll',
        'onnxruntime_providers_shared.dll',
        'sherpa-onnx-c-api.dll',
      ]) {
        final f = '$pkg\\$n';
        if (File(f).existsSync()) DynamicLibrary.open(f);
      }
      sherpa.initBindings();
      final tts = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            vits: sherpa.OfflineTtsVitsModelConfig(
              model: pack!.model,
              lexicon: '',
              tokens: pack.tokens,
              dataDir: pack.dataDir,
            ),
            numThreads: 2,
            provider: 'cpu',
          ),
          maxNumSenetences: 1,
        ),
      );
      final a = tts.generate(
        text: 'В начале Бог создал небо и землю.',
        sid: 0,
        speed: 1.0,
      );
      tts.free();
      expect(a.sampleRate, greaterThan(8000));
      // ~2 секунды речи на фразу — звук явно не пустой.
      expect(a.samples.length, greaterThan(a.sampleRate));
      expect(a.samples.any((s) => s.abs() > 0.01), isTrue);
      // Реальный WAV для прослушивания: кодировка та же, что у
      // нейробэкенда (wavFromPcm).
      final wav = File('$root\\sample.wav')
        ..writeAsBytesSync(wavFromPcm(a.samples, a.sampleRate));
      // ignore: avoid_print
      print(
        'synth ok: ${a.samples.length} samples @ ${a.sampleRate} Hz '
        '(${(a.samples.length / a.sampleRate).toStringAsFixed(2)}s)'
        ' → ${wav.path}',
      );
    },
    skip: pack == null ? 'нет голосового пакета' : false,
  );
}
