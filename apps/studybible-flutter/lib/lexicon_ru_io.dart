/// Русский словарь Стронга: загрузка с диска (dart:io).
///
/// Файл — пользовательские данные: STUDYBIBLE_DATA/dictionaries/strongs_ru.json
/// (по умолчанию ~/StudyBible-data, на Windows C:\StudyBible-data).
/// Нет файла — null, приложение остаётся на английском словаре.
library;

import 'dart:convert';
import 'dart:io';

String _dataDir() {
  final env = Platform.environment['STUDYBIBLE_DATA'];
  if (env != null && env.isNotEmpty) return env;
  if (Platform.isWindows) return r'C:\StudyBible-data';
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  return '$home${Platform.pathSeparator}StudyBible-data';
}

/// JSON-объект {номер: статья} или null, если файла нет/не читается.
Future<Map<String, dynamic>?> loadRussianLexiconJson() async {
  try {
    final f = File(
      '$_dataDir()${Platform.pathSeparator}dictionaries${Platform.pathSeparator}strongs_ru.json',
    );
    if (!f.existsSync()) return null;
    final j = jsonDecode(await f.readAsString());
    return j is Map<String, dynamic> ? j : null;
  } catch (_) {
    return null;
  }
}
