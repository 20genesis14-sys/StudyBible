/// Заглушка реестра для web: пакетов нет, нейробэкенд недоступен.
library;

import 'voice_pack.dart';

String voicesDir() => '';

List<VoicePack> scanVoices([String? dir]) => const [];
