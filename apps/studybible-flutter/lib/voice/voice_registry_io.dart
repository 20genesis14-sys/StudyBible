/// Сканирование `STUDYBIBLE_DATA/voices/`: каждая подпапка —
/// голосовой пакет VITS (распакованный `vits-piper-*` от k2-fsa
/// или сырой Piper `*.onnx` + `*.onnx.json` + `tokens.txt` +
/// `espeak-ng-data/`).
library;

import 'dart:convert';
import 'dart:io';

import '../native_bridge_io.dart' show dataDir;
import 'voice_pack.dart';

String voicesDir() => '${dataDir()}${Platform.pathSeparator}voices';

/// Найти файл/папку в корне пакета или на один уровень глубже.
String? _find(Directory dir, bool Function(String name) test) {
  try {
    for (final e in dir.listSync()) {
      if (test(e.path.split(Platform.pathSeparator).last)) return e.path;
      if (e is Directory) {
        for (final s in e.listSync()) {
          if (test(s.path.split(Platform.pathSeparator).last)) {
            return s.path;
          }
        }
      }
    }
  } catch (_) {}
  return null;
}

/// Сканировать голосовые пакеты. Папки без `.onnx` пропускаются;
/// пакет с недостающими частями возвращается с описанием в
/// `issues` (в настройках показывается выключенным с причиной).
/// [dir] — переопределение корня для тестов.
List<VoicePack> scanVoices([String? dir]) {
  final rootDir = dir ?? voicesDir();
  final root = Directory(rootDir);
  if (!root.existsSync()) return const [];
  // Общий espeak-ng-data на все пакеты, если положен рядом.
  final sharedData = '$rootDir${Platform.pathSeparator}espeak-ng-data';
  final hasShared = Directory(sharedData).existsSync();
  final out = <VoicePack>[];
  for (final e in root.listSync()) {
    if (e is! Directory) continue;
    final id = e.path.split(Platform.pathSeparator).last;
    if (id == 'espeak-ng-data') continue;
    final dir = Directory(e.path);

    // Модель: первый .onnx без 'int8' в имени (quantized — запасной).
    final models = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.onnx') && !f.path.endsWith('.onnx.json'),
        )
        .map((f) => f.path)
        .toList()
      ..sort();
    if (models.isEmpty) continue;
    final model =
        models.where((m) => !m.contains('int8')).firstOrNull ??
        models.first;

    // Piper-конфиг <модель>.onnx.json: язык, дикторы, имя.
    var piper = <String, Object?>{};
    final pj = File('$model.json');
    if (pj.existsSync()) {
      try {
        piper = jsonDecode(pj.readAsStringSync()) as Map<String, Object?>;
      } catch (_) {}
    }
    // Пользовательские переопределения.
    var meta = <String, Object?>{};
    final mj = File('${e.path}${Platform.pathSeparator}voice.json');
    if (mj.existsSync()) {
      try {
        meta = jsonDecode(mj.readAsStringSync()) as Map<String, Object?>;
      } catch (_) {}
    }

    final tokens = _find(dir, (n) => n == 'tokens.txt');
    final dataDir = _find(dir, (n) => n == 'espeak-ng-data');
    final issues = <String>[
      if (tokens == null) 'нет tokens.txt',
      if (dataDir == null && !hasShared) 'нет espeak-ng-data',
    ];
    out.add(
      VoicePack(
        id: id,
        dir: e.path,
        name: (meta['name'] as String?) ?? packName(id, piper),
        language:
            ((meta['language'] as String?) ?? packLanguage(id, piper))
                .toLowerCase(),
        model: model,
        tokens: tokens ?? '',
        dataDir: dataDir ?? (hasShared ? sharedData : ''),
        speakers: packSpeakers(piper),
        issues: issues,
      ),
    );
  }
  out.sort((a, b) => a.id.compareTo(b.id));
  return out;
}
