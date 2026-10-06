/// Импорт голосового пакета: архив (`.tar.bz2` от k2-fsa, `.zip`,
/// `.tar.gz`) распаковывается в `STUDYBIBLE_DATA/voices/`, папка —
/// копируется туда же. После импорта `scanVoices()` подхватывает
/// пакет, как rescanModules подхватывает .sb.
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';

import '../l10n.dart';
import 'voice_registry_io.dart' show voicesDir;

/// Отказаться от путей, выходящих за пределы каталога распаковки
/// (архив выбирает пользователь, но `../` внутри — не место файлам).
bool _safePaths(Archive a) {
  for (final f in a.files) {
    if (f.name.contains('..')) return false;
  }
  return true;
}

Archive? _decodeArchive(List<int> bytes) {
  if (bytes.length < 4) return null;
  // zip — PK\x03\x04; bzip2 — 'BZh'; gzip — 1F 8B; tar — 'ustar'@257.
  if (bytes[0] == 0x50 && bytes[1] == 0x4B) {
    return ZipDecoder().decodeBytes(bytes);
  }
  if (bytes[0] == 0x42 && bytes[1] == 0x5A && bytes[2] == 0x68) {
    return TarDecoder().decodeBytes(
      BZip2Decoder().decodeBytes(bytes),
    );
  }
  if (bytes[0] == 0x1F && bytes[1] == 0x8B) {
    return TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
  }
  if (bytes.length > 262 && bytes[257] == 0x75 /* 'ustar' */) {
    return TarDecoder().decodeBytes(bytes);
  }
  return null;
}

/// Выбрать архив голосового пакета и распаковать в `voices/`.
Future<String?> importVoicePackArchive() async {
  final files = await FilePicker.pickFiles(
    dialogTitle: tr(
      'Голосовой пакет (.tar.bz2/.zip)',
      'Voice pack (.tar.bz2/.zip)',
    ),
    type: FileType.custom,
    allowedExtensions: ['bz2', 'zip', 'tar', 'gz', 'tgz', 'tbz2'],
  );
  final file = files.firstOrNull;
  if (file == null) return null;
  final src = file.path;
  if (src == null) {
    return tr('Не удалось получить путь к файлу', 'Could not get file path');
  }
  try {
    final archive = _decodeArchive(await File(src).readAsBytes());
    if (archive == null) {
      return tr('Неизвестный формат архива', 'Unknown archive format');
    }
    if (!_safePaths(archive)) {
      return tr('Архив содержит небезопасные пути', 'Archive has unsafe paths');
    }
    final root = Directory(voicesDir());
    await root.create(recursive: true);
    await extractArchiveToDisk(archive, root.path);
    return tr('Импортирован: ${file.name}', 'Imported: ${file.name}');
  } catch (e) {
    return tr('Ошибка импорта: $e', 'Import error: $e');
  }
}

/// Выбрать распакованную папку пакета и скопировать её в `voices/`.
Future<String?> importVoicePackFolder() async {
  final dir = await FilePicker.getDirectoryPath(
    dialogTitle: tr(
      'Папка голосового пакета',
      'Voice pack folder',
    ),
  );
  if (dir == null) return null;
  final name = dir.split(Platform.pathSeparator).last;
  try {
    final dst = Directory('${voicesDir()}${Platform.pathSeparator}$name');
    await dst.create(recursive: true);
    await for (final e in Directory(dir).list(recursive: true)) {
      if (e is File) {
        final rel = e.path.substring(dir.length + 1);
        final to =
            File('${dst.path}${Platform.pathSeparator}$rel');
        await to.parent.create(recursive: true);
        await e.copy(to.path);
      }
    }
    return tr('Импортирован: $name', 'Imported: $name');
  } catch (e) {
    return tr('Ошибка импорта: $e', 'Import error: $e');
  }
}
