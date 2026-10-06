/// Импорт .sb/.sbz-модуля через file_picker: копирует файл в каталог
/// модулей приложения, после чего rescanModules() подхватывает его.
/// Сжатый .sbz распаковывается мостом при первом открытии (ADR 0016).
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'l10n.dart';
import 'native_bridge_io.dart' show dataDir;

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
  final modulesDir = Directory('${dataDir()}/modules');
  await modulesDir.create(recursive: true);
  final dst = '${modulesDir.path}/${file.name}';
  try {
    await File(src).copy(dst);
  } catch (e) {
    return tr('Ошибка импорта: $e', 'Import error: $e');
  }
  return tr('Импортирован: ${file.name}', 'Imported: ${file.name}');
}
