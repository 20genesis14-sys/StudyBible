/// Заглушка экспорта/импорта записей для web: файловой системы нет.
library;

import 'l10n.dart';

Future<String?> exportEntriesZip() async => tr(
  'Экспорт записей поддерживается на десктопе и Android',
  'Entries export is supported in the desktop and Android builds',
);

Future<String?> importEntriesZip() async => tr(
  'Импорт записей поддерживается на десктопе и Android',
  'Entries import is supported in the desktop and Android builds',
);
