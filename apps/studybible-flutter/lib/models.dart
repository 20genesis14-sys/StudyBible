/// Модели данных прототипа: разбор JSON, выгруженного из модулей `.sb`
/// (см. apps/studybible-cli/src/bin/export.rs).
///
/// Формат JSON:
///   { "id","title","language",
///     "books":  [ {"code":"GEN","title":"Бытие","chapters":50} ],
///     "chapters": { "GEN:1": {"n":1,"blocks":[ {"k":"p|q|h|d|b","m":"p",
///                   "s":[ {"v":1} | {"t":"...","s":"wj","a":"strong=\"H7225\""}
///                         | {"n":"f|x","c":"+","t":"..."} ] } ] } } }
library;

import 'dart:convert';

/// Загрузчик главы из внешнего источника (.sb через мост).
/// Возвращает JSON-кусок формата export.rs `{"n":..,"blocks":[..]}` или null.
typedef ChapterJsonLoader = Future<String?> Function(String code, int n);

class ModuleDoc {
  final String id;
  final String title;
  final String language;

  /// Тип модуля (ADR 0016): bible/interlinear/commentary/dictionary/
  /// layer/critical. Пусто у старых документов — читается как bible.
  final String kind;

  /// Необязательные возможности: strongs, morph, tokens, alignment,
  /// variants. Пусто — либо старый модуль, либо простой текст.
  final List<String> features;

  /// Флаги прав (ADR 0016): no-distribute, no-net, no-ai, no-plugins.
  final List<String> rights;

  /// Имя версификации Paratext ('rsc','eng','org',…; '' — неизвестна).
  /// Используется сравнением переводов (вопрос 8, vrs.dart).
  final String versification;

  final List<BookDoc> books;
  final Map<String, ChapterDoc> chapters;

  /// 'GEN:1' -> 31 — число стихов в каждой главе модуля.
  final Map<String, int> verseCounts;

  /// Для .sb-документов: ленивая загрузка глав через мост.
  /// У предвыгруженных JSON-документов null — все главы уже в [chapters].
  final ChapterJsonLoader? chapterLoader;

  /// 'code:n' -> идущий запрос (чтобы не грузить одну главу дважды).
  final Map<String, Future<ChapterDoc?>> _pending = {};

  ModuleDoc({
    required this.id,
    required this.title,
    required this.language,
    this.kind = 'bible',
    this.features = const [],
    this.rights = const [],
    this.versification = '',
    required this.books,
    required this.chapters,
    required this.verseCounts,
    this.chapterLoader,
  });

  /// true, если модуль объявляет возможность [f] (или у старого
  /// модуля список пуст — тогда UI ничего не прячет).
  bool hasFeature(String f) => features.isEmpty || features.contains(f);

  factory ModuleDoc.fromJson(Map<String, dynamic> j) => ModuleDoc(
    id: j['id'] as String,
    title: j['title'] as String,
    language: j['language'] as String? ?? '',
    kind: (j['kind'] as String?)?.isNotEmpty == true
        ? j['kind'] as String
        : 'bible',
    features:
        (j['features'] as List?)?.map((e) => e as String).toList() ??
        const [],
    rights:
        (j['rights'] as List?)?.map((e) => e as String).toList() ??
        const [],
    versification: j['versification'] as String? ?? '',
    books: (j['books'] as List)
        .map((b) => BookDoc.fromJson(b as Map<String, dynamic>))
        .toList(),
    chapters: (j['chapters'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, ChapterDoc.fromJson(v as Map<String, dynamic>)),
    ),
    verseCounts:
        (j['verse_counts'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, (v as num).toInt()),
        ) ??
        const {},
  );

  ChapterDoc? chapter(String code, int n) => chapters['$code:$n'];

  /// Подгрузить главу из источника, если её ещё нет в [chapters].
  /// Для JSON-документов завершается сразу. Повторные вызовы
  /// переиспользуют один и тот же Future.
  Future<ChapterDoc?> ensureChapter(String code, int n) {
    final key = '$code:$n';
    final cached = chapters[key];
    if (cached != null) return Future.value(cached);
    if (_pending.containsKey(key)) return _pending[key]!;
    final loader = chapterLoader;
    if (loader == null) return Future.value(null);
    final fut = loader(code, n).then((raw) {
      _pending.remove(key);
      if (raw == null) return null;
      final ch = ChapterDoc.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      chapters[key] = ch;
      return ch;
    });
    _pending[key] = fut;
    return fut;
  }

  /// Число стихов главы (0 — если неизвестно).
  int verseCount(String code, int n) => verseCounts['$code:$n'] ?? 0;

  BookDoc? bookByCode(String code) {
    for (final b in books) {
      if (b.code == code) return b;
    }
    return null;
  }
}

class BookDoc {
  final String code; // 'GEN', 'PSA', ...
  final String title; // полное название из модуля
  final int chapters;

  BookDoc({required this.code, required this.title, required this.chapters});

  factory BookDoc.fromJson(Map<String, dynamic> j) => BookDoc(
    code: j['code'] as String,
    title: j['title'] as String,
    chapters: j['chapters'] as int,
  );
}

class ChapterDoc {
  final int number;
  final List<BlockDoc> blocks;

  /// Варианты критического аппарата главы (ADR 0016).
  final List<VariantDoc> variants;

  ChapterDoc({
    required this.number,
    required this.blocks,
    this.variants = const [],
  });

  factory ChapterDoc.fromJson(Map<String, dynamic> j) => ChapterDoc(
    number: j['n'] as int,
    blocks: (j['blocks'] as List)
        .map((b) => BlockDoc.fromJson(b as Map<String, dynamic>))
        .toList(),
    variants:
        (j['variants'] as List?)
            ?.map((v) => VariantDoc.fromJson(v as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}

/// Вариант аппарата: место (стих + диапазон токенов) и чтения.
class VariantDoc {
  final int verse;
  final int tokenFrom;
  final int tokenTo;
  final List<ReadingDoc> readings;

  VariantDoc({
    required this.verse,
    required this.tokenFrom,
    required this.tokenTo,
    required this.readings,
  });

  factory VariantDoc.fromJson(Map<String, dynamic> j) => VariantDoc(
    verse: j['verse'] as int,
    tokenFrom: j['from'] as int,
    tokenTo: j['to'] as int,
    readings: (j['readings'] as List)
        .map((r) => ReadingDoc.fromJson(r as Map<String, dynamic>))
        .toList(),
  );
}

/// Чтение варианта: текст, признак базисного, сиглы свидетелей.
class ReadingDoc {
  final String text;
  final bool isBase;
  final List<String> witnesses;

  ReadingDoc({required this.text, required this.isBase, required this.witnesses});

  factory ReadingDoc.fromJson(Map<String, dynamic> j) => ReadingDoc(
    text: j['t'] as String? ?? '',
    isBase: j['base'] as bool? ?? false,
    witnesses:
        (j['w'] as List?)?.map((e) => e as String).toList() ?? const [],
  );
}

/// Тип блока: p — абзац, q — поэзия, h — заголовок, d — надписание, b — пустой.
enum BlockKind { paragraph, poetry, heading, superscription, blank }

class BlockDoc {
  final BlockKind kind;
  final String marker;
  final List<SpanDoc> spans;

  BlockDoc({required this.kind, required this.marker, required this.spans});

  factory BlockDoc.fromJson(Map<String, dynamic> j) => BlockDoc(
    kind: switch (j['k']) {
      'q' => BlockKind.poetry,
      'h' => BlockKind.heading,
      'd' => BlockKind.superscription,
      'b' => BlockKind.blank,
      _ => BlockKind.paragraph,
    },
    marker: j['m'] as String? ?? '',
    spans: (j['s'] as List)
        .map((s) => SpanDoc.fromJson(s as Map<String, dynamic>))
        .toList(),
  );
}

sealed class SpanDoc {
  const SpanDoc._();

  factory SpanDoc.fromJson(Map<String, dynamic> j) {
    if (j.containsKey('v')) return VerseSpanDoc(j['v'] as int);
    if (j.containsKey('n')) {
      return NoteSpanDoc(
        kind: j['n'] as String, // 'f' сноска, 'x' параллельное место
        caller: j['c'] as String? ?? '',
        text: j['t'] as String? ?? '',
        attrs: j['a'] as String? ?? '', // 'part="a" q="…"' (ADR 0016)
      );
    }
    return TextSpanDoc(
      text: j['t'] as String? ?? '',
      style: j['s'] as String? ?? '', // 'wj','add','w','nd',...
      attrs: j['a'] as String? ?? '', // 'strong="H7225"'
    );
  }
}

class VerseSpanDoc extends SpanDoc {
  final int verse;
  const VerseSpanDoc(this.verse) : super._();
}

class TextSpanDoc extends SpanDoc {
  final String text;
  final String style;
  final String attrs;
  const TextSpanDoc({
    required this.text,
    required this.style,
    required this.attrs,
  }) : super._();

  /// Номер Стронга вида 'H7225'/'G25', если есть.
  String? get strong {
    final m = RegExp(r'strong="([HG]\d+)"').firstMatch(attrs);
    return m?.group(1);
  }
}

class NoteSpanDoc extends SpanDoc {
  final String kind; // 'f' | 'x'
  final String caller;
  final String text;

  /// Атрибуты привязки к части стиха (ADR 0016): `part="a"`,
  /// `q="цитируемый текст"`. Пусто — ссылка на целый стих.
  final String attrs;
  const NoteSpanDoc({
    required this.kind,
    required this.caller,
    required this.text,
    this.attrs = '',
  }) : super._();

  String? _attr(String key) {
    final m = RegExp('$key="([^"]*)"').firstMatch(attrs);
    return m?.group(1);
  }

  /// Буква части стиха ('a' из «1:1a»), если задана.
  String? get part => _attr('part');

  /// Цитируемый текст привязки (\fq/\xq, catchWord), если задан.
  String? get anchor => _attr('q');
}

/// Простой текст стихов [v]..[vEnd] главы [ch] — без сносок,
/// стилей и номеров стихов (для карточек параллельных мест).
String verseText(ChapterDoc ch, int v, [int? vEnd]) {
  final end = vEnd ?? v;
  final buf = StringBuffer();
  var inside = false;
  for (final b in ch.blocks) {
    for (final s in b.spans) {
      if (s is VerseSpanDoc) {
        inside = s.verse >= v && s.verse <= end;
        if (inside && buf.isNotEmpty) buf.write(' ');
      } else if (inside && s is TextSpanDoc) {
        buf.write(s.text);
      }
    }
  }
  return buf.toString().trim();
}
