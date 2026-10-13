/// Русский словарь Стронга: загрузка с диска (dart:io).
///
/// Места поиска по порядку:
/// 1. `dataDir()/dictionaries/strongs_ru.json` — приватный каталог
///    приложения; сюда кладёт импорт (единственный путь на
///    Android 13+, куда руками не попасть).
/// 2. `STUDYBIBLE_DATA/dictionaries/strongs_ru.json` — dev-данные
///    (по умолчанию ~/StudyBible-data, на Windows C:\StudyBible-data).
/// Нет файла нигде — null, приложение остаётся на английском словаре.
library;

import 'dart:convert';
import 'dart:io';

import 'native_bridge_io.dart' show dataDir;

String _devDataDir() {
  final env = Platform.environment['STUDYBIBLE_DATA'];
  if (env != null && env.isNotEmpty) return env;
  if (Platform.isWindows) return r'C:\StudyBible-data';
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  return '$home${Platform.pathSeparator}StudyBible-data';
}

/// JSON-объект {номер: статья} или null, если файла нет/не читается.
Future<Map<String, dynamic>?> loadRussianLexiconJson() async {
  final sep = Platform.pathSeparator;
  for (final dir in {dataDir(), _devDataDir()}) {
    try {
      final f = File('$dir${sep}dictionaries${sep}strongs_ru.json');
      if (!f.existsSync()) continue;
      final j = jsonDecode(await f.readAsString());
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
  }
  return null;
}
