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
