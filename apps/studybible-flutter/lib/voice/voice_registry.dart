/// Реестр голосовых пакетов. На нативных платформах сканирует
/// `STUDYBIBLE_DATA/voices/`; на web голосовых пакетов нет.
library;

export 'voice_registry_stub.dart'
    if (dart.library.io) 'voice_registry_io.dart';
