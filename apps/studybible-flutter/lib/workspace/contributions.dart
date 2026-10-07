/// Реестр вкладов (ADR 0020): единая точка регистрации слоёв, панелей,
/// действий и пресетов. Встроенные фичи оформляются теми же
/// дескрипторами, что получат внешние плагины — API точек расширения
/// обкатывается на себе до публикации.
///
/// `typeId` вклада неизменен после публикации (правило SMAPI):
/// сохранённые раскладки ссылаются на него, переименование ломает
/// userdata. Неизвестный typeId мягко пропускается.
library;

import '../l10n.dart';
import '../models.dart';

/// Род вклада.
enum ContributionKind { layer, pane, action, preset }

/// Вклад: слой панели, панель, действие меню или пресет раскладки.
class Contribution {
  const Contribution({
    required this.id,
    required this.kind,
    required this.titleRu,
    required this.titleEn,
    this.subtitleRu = '',
    this.subtitleEn = '',
    this.requires = const [],
    this.order = 0,
    this.options = const {},
  });

  /// Стабильный идентификатор (вечный после публикации).
  final String id;
  final ContributionKind kind;
  final String titleRu;
  final String titleEn;

  /// Подпись-пояснение в листе слоёв (может быть пустой).
  final String subtitleRu;
  final String subtitleEn;

  /// Необходимые `meta.features` модуля: вклад доступен, только если
  /// модуль несёт все перечисленные (пустой список — всегда).
  final List<String> requires;

  /// Порядок среди вкладов своего рода: меньше — выше в списке.
  /// Спорный слот решается явным порядком, не «кто последний».
  final int order;

  /// Свободные опции дескриптора (как LayerConfig.options).
  final Map<String, Object?> options;

  String get title => tr(titleRu, titleEn);
  String get subtitle => subtitleRu.isEmpty && subtitleEn.isEmpty
      ? ''
      : tr(subtitleRu, subtitleEn);

  /// Доступен ли вклад для модуля с такими features.
  /// Пустой список features модуля читается как «есть всё»
  /// (та же мягкость, что в `ModuleDoc.hasFeature`).
  bool availableFor(ModuleDoc? module) {
    if (module == null || requires.isEmpty) return true;
    return requires.every(module.hasFeature);
  }
}

/// Реестр вкладов. Данные, не виджеты: без импорта material.
class ContributionRegistry {
  final _items = <String, Contribution>{};

  /// Регистрация. Повторный id — ошибка разработчика: id вечны,
  /// тихая перезапись скрыла бы конфликт двух вкладов.
  void register(Contribution c) {
    if (_items.containsKey(c.id)) {
      throw ArgumentError('duplicate contribution id: ${c.id}');
    }
    _items[c.id] = c;
  }

  Contribution? resolve(String id) => _items[id];

  /// Вклады рода в явном порядке (`order`, затем id для
  /// детерминизма при равном приоритете).
  List<Contribution> ofKind(ContributionKind kind) {
    final list = _items.values.where((c) => c.kind == kind).toList()
      ..sort((a, b) {
        final o = a.order.compareTo(b.order);
        return o != 0 ? o : a.id.compareTo(b.id);
      });
    return List.unmodifiable(list);
  }

  /// Вклады рода, доступные модулю (проверка `requires`).
  List<Contribution> available(ContributionKind kind, ModuleDoc? module) =>
      List.unmodifiable(ofKind(kind).where((c) => c.availableFor(module)));
}

/// Встроенные вклады приложения (built-in): слои панели чтения,
/// пресеты раскладки и действия меню стиха. Id — контракт:
/// сохранённые раскладки и будущие плагины ссылаются на них.
void _registerBuiltins(ContributionRegistry r) {
  for (final c in const <Contribution>[
    // Слои читалки. Порядок — порядок строк в листе «Слои».
    Contribution(
      id: 'layer.compare',
      kind: ContributionKind.layer,
      titleRu: 'Подстрочное сравнение',
      titleEn: 'Interleaved compare',
      subtitleRu: 'Другие переводы под каждым стихом',
      subtitleEn: 'Other translations under each verse',
      order: 10,
    ),
    Contribution(
      id: 'layer.footnotes',
      kind: ContributionKind.layer,
      titleRu: 'Сноски',
      titleEn: 'Footnotes',
      order: 20,
    ),
    Contribution(
      id: 'layer.xrefs',
      kind: ContributionKind.layer,
      titleRu: 'Параллельные места',
      titleEn: 'Cross-references',
      order: 30,
    ),
    Contribution(
      id: 'layer.strongs',
      kind: ContributionKind.layer,
      titleRu: 'Номера Стронга',
      titleEn: 'Strong’s numbers',
      requires: ['strongs'],
      order: 40,
    ),
    // Пресеты раскладки — сохранённые наборы слоёв и режима.
    Contribution(
      id: 'preset.reading',
      kind: ContributionKind.preset,
      titleRu: 'Чтение',
      titleEn: 'Reading',
      subtitleRu: 'Чистый текст',
      subtitleEn: 'Clean text',
      order: 10,
    ),
    Contribution(
      id: 'preset.study',
      kind: ContributionKind.preset,
      titleRu: 'Изучение',
      titleEn: 'Study',
      subtitleRu: 'Стих на строку, метки, сноски',
      subtitleEn: 'Verse per line, marks, footnotes',
      order: 20,
    ),
  ]) {
    r.register(c);
  }
}

/// Глобальный реестр вкладов. Синглтон в стиле services (`state.dart`):
/// реестр неизменен после регистрации встроенных вкладов.
final contributions = _buildContributions();

ContributionRegistry _buildContributions() {
  final r = ContributionRegistry();
  _registerBuiltins(r);
  return r;
}
