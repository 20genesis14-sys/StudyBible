/// Вложения к заметкам (десктоп/Android): файлы в
/// `<datadir>/attachments/<id>`, индекс — `attachments.json` рядом.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'native_bridge_io.dart' show dataDir;

class AttachInfo {
  const AttachInfo({
    required this.id,
    required this.entryId,
    required this.name,
    required this.mime,
  });
  final String id, entryId, name, mime;
}

File _index() => File('${dataDir()}/attachments.json');

Directory _dir() => Directory('${dataDir()}/attachments');

List<Map<String, dynamic>> _read() {
  final f = _index();
  if (!f.existsSync()) return [];
  try {
    return (jsonDecode(f.readAsStringSync()) as List)
        .whereType<Map<String, dynamic>>()
        .toList();
  } catch (_) {
    return [];
  }
}

void _write(List<Map<String, dynamic>> list) {
  _dir().createSync(recursive: true);
  _index().writeAsStringSync(jsonEncode(list));
}

String _newId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    (DateTime.now().millisecondsSinceEpoch % 997).toString();

/// Вложения одной записи-заметки.
Future<List<AttachInfo>> attachList(String entryId) async => [
  for (final m in _read())
    if (m['entryId'] == entryId)
      AttachInfo(
        id: '${m['id']}',
        entryId: '${m['entryId']}',
        name: '${m['name'] ?? ''}',
        mime: '${m['mime'] ?? ''}',
      ),
];

/// Сохранить файл вложения и записать его в индекс.
Future<AttachInfo?> attachAdd({
  required String entryId,
  required String name,
  required String mime,
  required Uint8List bytes,
}) async {
  final id = _newId();
  _dir().createSync(recursive: true);
  await File('${_dir().path}/$id').writeAsBytes(bytes, flush: true);
  final list = _read();
  list.add({'id': id, 'entryId': entryId, 'name': name, 'mime': mime});
  _write(list);
  return AttachInfo(id: id, entryId: entryId, name: name, mime: mime);
}

Future<Uint8List?> attachBytes(AttachInfo a) async {
  final f = File('${_dir().path}/${a.id}');
  return f.existsSync() ? f.readAsBytes() : null;
}

/// Удалить вложение (и файл).
Future<void> attachRemove(String id) async {
  final list = _read()..removeWhere((m) => m['id'] == id);
  _write(list);
  final f = File('${_dir().path}/$id');
  if (f.existsSync()) f.deleteSync();
}

/// Все вложения записи (заметка удалена).
Future<void> attachRemoveFor(String entryId) async {
  final gone = _read().where((m) => m['entryId'] == entryId).toList();
  _write(_read()..removeWhere((m) => m['entryId'] == entryId));
  for (final m in gone) {
    final f = File('${_dir().path}/${m['id']}');
    if (f.existsSync()) f.deleteSync();
  }
}

// ---------- диктофон (record) ----------

/// Запись голоса доступна на нативных платформах.
bool attachCanRecord() => true;

AudioRecorder? _rec;
String? _recPath;

/// Начать запись (разрешение микрофона запрашивается плагином).
Future<bool> attachRecordStart() async {
  try {
    final rec = AudioRecorder();
    if (!await rec.hasPermission()) {
      rec.dispose();
      return false;
    }
    _dir().createSync(recursive: true);
    _recPath =
        '${_dir().path}/_rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: _recPath!,
    );
    _rec = rec;
    return true;
  } catch (_) {
    return false;
  }
}

/// Закончить запись → (name, mime, bytes) для attachAdd.
Future<({String name, String mime, Uint8List bytes})?>
attachRecordStop() async {
  final rec = _rec;
  _rec = null;
  if (rec == null) return null;
  try {
    await rec.stop();
  } finally {
    rec.dispose();
  }
  final p = _recPath;
  _recPath = null;
  if (p == null) return null;
  final f = File(p);
  if (!f.existsSync()) return null;
  final bytes = await f.readAsBytes();
  await f.delete();
  return (
    name: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
    mime: 'audio/mp4',
    bytes: bytes,
  );
}
