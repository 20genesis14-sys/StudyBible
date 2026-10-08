/// Нейробэкенд `neural` (sherpa_onnx, VITS/Piper) — вырезан из
/// релиза 1.0 ради размера (~73 МБ onnxruntime+sherpa на 3 ABI,
/// решение 12.10.2026, ADR 0017 «Статус»). Нативная реализация
/// `voice_neural_io.dart` восстанавливается из истории git вместе с
/// зависимостью `sherpa_onnx` в pubspec.
library;

export 'voice_neural_stub.dart';
