/// Модель голосового пакета (ADR 0017): распакованная папка в
/// `STUDYBIBLE_DATA/voices/<id>/` — VITS/Piper-совместимая модель
/// для sherpa-onnx. Чистые разборы живут здесь для тестов.
library;

/// Голосовой пакет VITS: `model.onnx` + `tokens.txt` +
/// `espeak-ng-data/` (внутри пакета или общая в `voices/`).
class VoicePack {
  const VoicePack({
    required this.id,
    required this.dir,
    required this.name,
    required this.language,
    required this.model,
    this.tokens = '',
    this.dataDir = '',
    this.speakers = 1,
    this.issues = const [],
  });

  /// Имя папки пакета.
  final String id;

  /// Абсолютный путь к папке.
  final String dir;

  /// Читаемое имя голоса (voice.json/piper json/имя папки).
  final String name;

  /// Двухбуквенный язык ('ru', 'en') — по нему подбирается голос.
  final String language;

  /// Путь к `*.onnx` модели.
  final String model;

  /// Путь к `tokens.txt` (обязателен для VITS).
  final String tokens;

  /// Путь к `espeak-ng-data` (обязателен для Piper-голосов).
  final String dataDir;

  /// Число дикторов в модели (sid для generate: 0..speakers-1).
  final int speakers;

  /// Причины негодности («нет tokens.txt» и т.п.) — пакет
  /// показывается в настройках выключенным с подсказкой.
  final List<String> issues;

  bool get usable => issues.isEmpty;
}

/// Язык пакета из piper-конфига (`*.onnx.json`): `language.code`
/// вида 'ru_RU' → 'ru'. Запасной путь — префикс имени папки
/// ('vits-piper-ru_RU-dmitri' → 'ru').
String packLanguage(String dirName, Map<String, Object?> piperJson) {
  final code = (piperJson['language'] as Map?)?['code'] as String?;
  if (code != null && code.length >= 2) {
    return code.substring(0, 2).toLowerCase();
  }
  final m = RegExp(r'([a-z]{2,3})_[A-Z]{2}').firstMatch(dirName);
  if (m != null) return m.group(1)!.toLowerCase();
  return '';
}

/// Имя голоса: `voice.json.name` → piper `dataset` → имя папки.
String packName(String dirName, Map<String, Object?> piperJson) {
  final ds = piperJson['dataset'] as String?;
  if (ds != null && ds.isNotEmpty) return ds;
  return dirName;
}

/// Число дикторов из piper-конфига: `num_speakers` или длина
/// `speaker_id_map`.
int packSpeakers(Map<String, Object?> piperJson) {
  final n = piperJson['num_speakers'];
  if (n is int && n > 0) return n;
  final smap = piperJson['speaker_id_map'];
  if (smap is Map && smap.isNotEmpty) return smap.length;
  return 1;
}

/// Выбор голоса для языка: явный выбор из настроек
/// (`neuralVoices` вида 'ru:id,en:id'), иначе первый годный.
VoicePack? voiceForLanguage(
  List<VoicePack> packs,
  String bcp47,
  String preferred,
) {
  final lang = bcp47.length >= 2
      ? bcp47.substring(0, 2).toLowerCase()
      : bcp47.toLowerCase();
  final pref = <String, String>{};
  for (final e in preferred.split(',')) {
    final i = e.indexOf(':');
    if (i > 0) pref[e.substring(0, i)] = e.substring(i + 1);
  }
  final want = pref[lang];
  if (want != null) {
    for (final p in packs) {
      if (p.id == want && p.usable) return p;
    }
  }
  for (final p in packs) {
    if (p.language == lang && p.usable) return p;
  }
  return null;
}
