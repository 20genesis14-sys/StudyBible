/// Заглушка вложений к заметкам для платформ без хранилища.
library;

import 'dart:typed_data';

class AttachInfo {
  const AttachInfo({
    required this.id,
    required this.entryId,
    required this.name,
    required this.mime,
  });
  final String id, entryId, name, mime;
}

Future<List<AttachInfo>> attachList(String entryId) async => const [];

Future<AttachInfo?> attachAdd({
  required String entryId,
  required String name,
  required String mime,
  required Uint8List bytes,
}) async => null;

Future<Uint8List?> attachBytes(AttachInfo a) async => null;

Future<void> attachRemove(String id) async {}

Future<void> attachRemoveFor(String entryId) async {}

// ---------- диктофон: заглушка ----------

bool attachCanRecord() => false;

Future<bool> attachRecordStart() async => false;

Future<({String name, String mime, Uint8List bytes})?>
attachRecordStop() async => null;
