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

/// Заголовок словарной статьи (зеркало api::DictEntry, ADR 0016).
class DictEntryInfo {
  /// Порядок в словаре — ключ для `bridgeDictEntry`.
  final int ord;
  final String headword;

  const DictEntryInfo({required this.ord, required this.headword});
}

/// Статья словаря (зеркало api::DictArticle).
class DictArticleInfo {
  final int ord;
  final String headword;
  final String text;

  const DictArticleInfo({
    required this.ord,
    required this.headword,
    required this.text,
  });
}
