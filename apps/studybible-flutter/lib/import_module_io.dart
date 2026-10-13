/// Импорт .sb/.sbz-модуля через file_picker: копирует файл в каталог
/// модулей приложения, после чего rescanModules() подхватывает его.
/// Сжатый .sbz распаковывается мостом при первом открытии (ADR 0016).
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'l10n.dart';
import 'native_bridge_io.dart'
    show bridgeEntriesRelink, bridgeModuleDoc, dataDir;

/// Возвращает текст результата для SnackBar или null при отмене.
Future<String?> importSbModule() async {
  final files = await FilePicker.pickFiles(
    dialogTitle: tr('Выберите модуль .sb/.sbz', 'Choose a .sb/.sbz module'),
    type: FileType.custom,
    allowedExtensions: ['sb', 'sbz'],
  );
  final file = files.firstOrNull;
  if (file == null) return null;
  final src = file.path;
  if (src == null) {
    return tr('Не удалось получить путь к файлу', 'Could not get file path');
  }
  // Идентичность модуля — meta.id, не имя файла: сохраняем как
  // `<id>.<ext>` — резолв записей и повторный импорт не зависят от
  // имени исходного файла.
  final doc = await bridgeModuleDoc(src);
  final id = doc == null
      ? null
      : (jsonDecode(doc) as Map<String, dynamic>)['id'] as String?;
  if (id == null || id.isEmpty) {
    return tr(
      'Не удалось прочитать модуль: ${file.name}',
      'Could not read module: ${file.name}',
    );
  }
  final ext = file.name.split('.').last;
  final modulesDir = Directory('${dataDir()}/modules');
  await modulesDir.create(recursive: true);
  final dst = '${modulesDir.path}/$id.$ext';
  try {
    await File(src).copy(dst);
  } catch (e) {
    return tr('Ошибка импорта: $e', 'Import error: $e');
  }
  // Обновлённый/новый модуль — проверить привязки записей (вопрос №12).
  final relink = await bridgeEntriesRelink();
  if (relink == null) {
    return tr('Импортирован: ${file.name}', 'Imported: ${file.name}');
  }
  return tr(
    'Импортирован: ${file.name}. Перепривязка: $relink',
    'Imported: ${file.name}. Relink: $relink',
  );
}

/// Импорт русского словаря Стронга: пользователь выбирает JSON,
/// файл копируется в `dataDir()/dictionaries/strongs_ru.json` —
/// приватный каталог приложения, доступный на Android 13+ только
/// изнутри приложения (поэтому нужен именно импорт, а не ручное
/// копирование). После импорта нужен lexiconReset() + перезагрузка.
Future<String?> importStrongsDict() async {
  final files = await FilePicker.pickFiles(
    dialogTitle: tr(
      'Выберите словарь Стронга (strongs_ru.json)',
      'Choose Strong\'s lexicon (strongs_ru.json)',
    ),
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  final file = files.firstOrNull;
  if (file == null) return null;
  final src = file.path;
  if (src == null) {
    return tr('Не удалось получить путь к файлу', 'Could not get file path');
  }
  // Проверка формата: JSON-объект {номер: статья}.
  try {
    final j = jsonDecode(await File(src).readAsString());
    if (j is! Map<String, dynamic> || j.isEmpty) {
      return tr(
        'Это не словарь Стронга: ${file.name}',
        'Not a Strong\'s lexicon: ${file.name}',
      );
    }
  } catch (_) {
    return tr(
      'Не удалось прочитать JSON: ${file.name}',
      'Could not read JSON: ${file.name}',
    );
  }
  final dictDir = Directory('${dataDir()}/dictionaries');
  await dictDir.create(recursive: true);
  try {
    await File(src).copy('${dictDir.path}/strongs_ru.json');
  } catch (e) {
    return tr('Ошибка импорта: $e', 'Import error: $e');
  }
  return tr(
    'Словарь Стронга импортирован: ${file.name}',
    'Strong\'s lexicon imported: ${file.name}',
  );
}
