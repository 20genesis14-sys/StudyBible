/// Нейробэкенд `neural` (sherpa_onnx, VITS/Piper) — только на
/// нативных платформах; на web — заглушка «недоступен».
library;

export 'voice_neural_stub.dart'
    if (dart.library.io) 'voice_neural_io.dart';
