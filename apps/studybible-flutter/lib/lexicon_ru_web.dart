/// Русский словарь Стронга: загрузка в браузере (package:web).
///
/// Файл лежит рядом с приложением (`dicts/strongs_ru.json`) только
/// в локальной/внутренней сборке — в публичную он не входит:
/// 404/ошибка → null, приложение остаётся на английском словаре.
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// JSON-объект {номер: статья} или null, если файла нет.
Future<Map<String, dynamic>?> loadRussianLexiconJson() async {
  try {
    final resp = await web.window.fetch('dicts/strongs_ru.json'.toJS).toDart;
    if (resp.status != 200) return null;
    final j = jsonDecode((await resp.text().toDart).toDart);
    return j is Map<String, dynamic> ? j : null;
  } catch (_) {
    return null;
  }
}
