/// Импорт голосового пакета (ADR 0017): папка или архив
/// `.tar.bz2`/`.zip`/`.tar.gz` — распаковка в `voices/`.
/// На web недоступно (заглушка).
library;

export 'voice_import_stub.dart'
    if (dart.library.io) 'voice_import_io.dart';
