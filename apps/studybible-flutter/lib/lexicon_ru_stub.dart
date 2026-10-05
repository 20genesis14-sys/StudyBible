/// Русский словарь Стронга: заглушка загрузчика.
///
/// Ни web, ни io не подходят — русских данных нет.
library;

/// JSON-объект {номер: статья} или null, если файла нет.
Future<Map<String, dynamic>?> loadRussianLexiconJson() async => null;
