/// Вложения к заметкам на web: localStorage (ключ sb.attach —
/// карта entryId -> [{id,name,mime,b64}]). Ограничение quota ~5 МБ:
/// для крупных файлов возвращаем null.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'attachments_stub.dart' show AttachInfo;
export 'attachments_stub.dart' show AttachInfo;

const _kAttach = 'sb.attach';

web.Storage get _s => web.window.localStorage;

Map<String, List<Map<String, String>>> _read() {
  try {
    final raw = _s.getItem(_kAttach);
    if (raw == null) return {};
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return {
      for (final e in m.entries)
        e.key: [
          for (final x in e.value as List) Map<String, String>.from(x as Map),
        ],
    };
  } catch (_) {
    return {};
  }
}

bool _write(Map<String, List<Map<String, String>>> m) {
  try {
    _s.setItem(_kAttach, jsonEncode(m));
    return true;
  } catch (_) {
    return false; // переполнение quota
  }
}

Future<List<AttachInfo>> attachList(String entryId) async => [
  for (final m in _read()[entryId] ?? const [])
    AttachInfo(
      id: '${m['id']}',
      entryId: entryId,
      name: '${m['name'] ?? ''}',
      mime: '${m['mime'] ?? ''}',
    ),
];

Future<AttachInfo?> attachAdd({
  required String entryId,
  required String name,
  required String mime,
  required Uint8List bytes,
}) async {
  if (bytes.length > 2 * 1024 * 1024) return null; // quota localStorage
  final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final m = _read();
  (m[entryId] ??= []).add({
    'id': id,
    'name': name,
    'mime': mime,
    'b64': base64Encode(bytes),
  });
  return _write(m)
      ? AttachInfo(id: id, entryId: entryId, name: name, mime: mime)
      : null;
}

Future<Uint8List?> attachBytes(AttachInfo a) async {
  for (final m in _read()[a.entryId] ?? const []) {
    if (m['id'] == a.id && m['b64'] != null) {
      try {
        return base64Decode(m['b64']!);
      } catch (_) {
        return null;
      }
    }
  }
  return null;
}

Future<void> attachRemove(String id) async {
  final m = _read();
  for (final e in m.entries) {
    e.value.removeWhere((x) => x['id'] == id);
  }
  m.removeWhere((_, v) => v.isEmpty);
  _write(m);
}

Future<void> attachRemoveFor(String entryId) async {
  final m = _read()..remove(entryId);
  _write(m);
}

// ---------- диктофон на web: пока не поддерживается ----------
// (record 7 умеет web через MediaRecorder, но отдаёт blob-URL;
// сохранение в localStorage больших аудио нецелесообразно — в плане).

bool attachCanRecord() => false;

Future<bool> attachRecordStart() async => false;

Future<({String name, String mime, Uint8List bytes})?>
attachRecordStop() async => null;
