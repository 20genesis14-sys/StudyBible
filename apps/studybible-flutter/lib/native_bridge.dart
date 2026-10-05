/// Общие типы источника модулей .sb (используются и стабом, и io-реализацией).
library;

/// Модуль .sb, найденный в каталоге данных.
class SbModuleInfo {
  final String id;
  final String title;
  final String language;
  final String path;

  const SbModuleInfo({
    required this.id,
    required this.title,
    required this.language,
    required this.path,
  });
}

/// Запись пользователя (заметка/закладка/выделение), зеркало api::UserEntryInfo.
class UserEntry {
  final String id;
  final String module;

  /// `"note" | "mark" | "hl"`.
  final String kind;
  final String book;
  final int chapter;
  final int verse;
  final String text;
  final String context;
  final int created;
  final int updated;

  const UserEntry({
    required this.id,
    required this.module,
    required this.kind,
    required this.book,
    required this.chapter,
    required this.verse,
    required this.text,
    required this.context,
    required this.created,
    required this.updated,
  });
}

/// Результат поиска по модулю, зеркало api::SearchHitInfo.
class SearchHit {
  final String book;
  final int chapter;
  final int verse;
  final String snippet;

  const SearchHit({
    required this.book,
    required this.chapter,
    required this.verse,
    required this.snippet,
  });
}
