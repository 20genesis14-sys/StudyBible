/// Заглушка импорта модулей для web: файлового каталога данных
/// в браузере нет, импорт .sb поддерживается на десктопе и Android.
library;

import 'l10n.dart';

/// Возвращает текст результата для SnackBar или null при отмене.
Future<String?> importSbModule() async => tr(
  'Импорт .sb поддерживается в настольной и Android-версии',
  '.sb import is supported in the desktop and Android builds',
);
