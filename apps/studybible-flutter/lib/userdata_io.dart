/// Экспорт/импорт записей пользователя (userdata.zip) через
/// file_picker — кнопки на экране «Записи». Rust-ядро пишет/читает
/// zip; через file_picker отдаём/берём байты (Android SAF не даёт
/// обычный путь для записи).
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'l10n.dart';
import 'native_bridge_io.dart'
    show
        bridgeEntriesExport,
        bridgeEntriesExportMd,
        bridgeEntriesImport,
        dataDir;

/// Экспорт всех записей в выбранный пользователем zip.
/// Возвращает текст для SnackBar или null при отмене.
Future<String?> exportEntriesZip() async {
  final tmp = File('${dataDir()}${Platform.pathSeparator}userdata-export.zip');
  final n = await bridgeEntriesExport(tmp.path);
  if (n == null || !await tmp.exists()) {
    return tr('Ошибка экспорта записей', 'Entries export failed');
  }
  final bytes = await tmp.readAsBytes();
  final out = await FilePicker.saveFile(
    dialogTitle: tr('Экспорт записей', 'Export entries'),
    fileName: 'userdata.zip',
    bytes: bytes,
  );
  if (out == null) return null;
  return tr('Экспортировано записей: $n', 'Exported entries: $n');
}

/// Экспорт всех записей в выбранный Markdown-файл (только экспорт).
/// Возвращает текст для SnackBar или null при отмене.
Future<String?> exportEntriesMd() async {
  final tmp = File('${dataDir()}${Platform.pathSeparator}userdata-export.md');
  final n = await bridgeEntriesExportMd(tmp.path);
  if (n == null || !await tmp.exists()) {
    return tr('Ошибка экспорта записей', 'Entries export failed');
  }
  final bytes = await tmp.readAsBytes();
  final out = await FilePicker.saveFile(
    dialogTitle: tr('Экспорт записей в Markdown', 'Export entries to Markdown'),
    fileName: 'userdata.md',
    bytes: bytes,
  );
  if (out == null) return null;
  return tr('Экспортировано записей: $n', 'Exported entries: $n');
}

/// Импорт записей из выбранного zip («свежее updated побеждает»).
/// Возвращает текст для SnackBar или null при отмене.
Future<String?> importEntriesZip() async {
  final files = await FilePicker.pickFiles(
    dialogTitle: tr('Импорт записей', 'Import entries'),
    type: FileType.custom,
    allowedExtensions: ['zip'],
  );
  final src = files.firstOrNull?.path;
  if (src == null) return null;
  final r = await bridgeEntriesImport(src);
  if (r == null) {
    return tr('Ошибка импорта записей', 'Entries import failed');
  }
  return tr('Импорт: $r', 'Import: $r');
}
