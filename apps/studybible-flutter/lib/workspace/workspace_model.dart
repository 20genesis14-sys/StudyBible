/// Модель интерфейса Workspace → Pane → Layer (ADR 0014).
///
/// Первая версия описывает текущую раскладку чтения: один Workspace,
/// одна панель `reader` и набор включённых слоёв. Формат JSON —
/// змеиный регистр, как в ADR и userdata.
library;

import 'dart:collection';

/// Тип раскладки рабочей области.
enum WorkspaceLayoutType { single, splitHorizontal, splitVertical, tabs }

/// Тип панели.
enum PaneType { reader, lexicon, notes, search, commentary, plugin, custom }

/// Тип слоя панели чтения.
enum LayerType {
  text,
  secondTranslation,
  interlinear,
  footnotes,
  xrefs,
  strongs,
  apparatus,
  notes,
  custom,
}

const _layoutTypeNames = <WorkspaceLayoutType, String>{
  WorkspaceLayoutType.single: 'single',
  WorkspaceLayoutType.splitHorizontal: 'split_horizontal',
  WorkspaceLayoutType.splitVertical: 'split_vertical',
  WorkspaceLayoutType.tabs: 'tabs',
};

const _paneTypeNames = <PaneType, String>{
  PaneType.reader: 'reader',
  PaneType.lexicon: 'lexicon',
  PaneType.notes: 'notes',
  PaneType.search: 'search',
  PaneType.commentary: 'commentary',
};

const _layerTypeNames = <LayerType, String>{
  LayerType.text: 'text',
  LayerType.secondTranslation: 'second_translation',
  LayerType.interlinear: 'interlinear',
  LayerType.footnotes: 'footnotes',
  LayerType.xrefs: 'xrefs',
  LayerType.strongs: 'strongs',
  LayerType.apparatus: 'apparatus',
  LayerType.notes: 'notes',
};

String _string(Map<String, Object?> j, String key, [String fallback = '']) =>
    j[key] as String? ?? fallback;

Map<String, Object?> _object(Map<String, Object?> j, String key) {
  final v = j[key];
  return v is Map ? Map<String, Object?>.from(v) : const {};
}

List<Map<String, Object?>> _objects(Map<String, Object?> j, String key) {
  final v = j[key];
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e is Map) Map<String, Object?>.from(e),
  ];
}

/// Раскладка рабочей области.
class WorkspaceLayoutSpec {
  const WorkspaceLayoutSpec(this.type, {this.ratio = 0.5});

  const WorkspaceLayoutSpec.single() : this(WorkspaceLayoutType.single);

  const WorkspaceLayoutSpec.splitHorizontal({double ratio = 0.5})
    : this(WorkspaceLayoutType.splitHorizontal, ratio: ratio);

  const WorkspaceLayoutSpec.splitVertical({double ratio = 0.5})
    : this(WorkspaceLayoutType.splitVertical, ratio: ratio);

  const WorkspaceLayoutSpec.tabs() : this(WorkspaceLayoutType.tabs);

  final WorkspaceLayoutType type;

  /// Доля первой области при разделении. Игнорируется для single/tabs.
  final double ratio;

  factory WorkspaceLayoutSpec.fromJson(Map<String, Object?> j) {
    final type = _layoutTypeNames.entries
        .where((e) => e.value == _string(j, 'type', 'single'))
        .map((e) => e.key)
        .firstOrNull;
    return WorkspaceLayoutSpec(
      type ?? WorkspaceLayoutType.single,
      ratio: (j['ratio'] as num? ?? 0.5).toDouble(),
    );
  }

  Map<String, Object?> toJson() => {
    'type': _layoutTypeNames[type],
    if (type == WorkspaceLayoutType.splitHorizontal ||
        type == WorkspaceLayoutType.splitVertical)
      'ratio': ratio,
  };
}

/// Слой внутри панели: текст, второй перевод, подстрочник и т.д.
class LayerConfig {
  LayerConfig(
    this.type, {
    Map<String, Object?> options = const {},
    this.customType,
  }) : options = UnmodifiableMapView(Map<String, Object?>.from(options));

  final LayerType type;

  /// Исходное имя неизвестного типа слоя (forward compatibility).
  final String? customType;

  /// Опции слоя — свободный JSON для конкретного слоя/плагина.
  final Map<String, Object?> options;

  String get typeName => type == LayerType.custom
      ? (customType ?? 'custom')
      : _layerTypeNames[type]!;

  factory LayerConfig.fromJson(Map<String, Object?> j) {
    final raw = _string(j, 'type', 'text');
    final type = _layerTypeNames.entries
        .where((e) => e.value == raw)
        .map((e) => e.key)
        .firstOrNull;
    return LayerConfig(
      type ?? LayerType.custom,
      customType: type == null ? raw : null,
      options: _object(j, 'options'),
    );
  }

  Map<String, Object?> toJson() => {'type': typeName, 'options': options};
}

/// Панель рабочей области.
class PaneConfig {
  PaneConfig({
    required this.id,
    required this.type,
    this.pluginId,
    this.customType,
    this.source = 'main',
    this.linkGroup,
    List<LayerConfig> layers = const [],
    Map<String, Object?> options = const {},
  }) : layers = List.unmodifiable(layers),
       options = UnmodifiableMapView(Map<String, Object?>.from(options));

  final String id;
  final PaneType type;

  /// Идентификатор плагина для `plugin:<id>` или неизвестного типа.
  final String? pluginId;

  /// Исходное имя неизвестного типа панели.
  final String? customType;

  /// `main` — основной перевод; иначе — id модуля.
  final String source;
  final String? linkGroup;
  final List<LayerConfig> layers;
  final Map<String, Object?> options;

  String get typeName {
    if (type == PaneType.plugin) return 'plugin:${pluginId ?? ''}';
    if (type == PaneType.custom) return customType ?? 'custom';
    return _paneTypeNames[type]!;
  }

  bool hasLayer(LayerType type) => layers.any((l) => l.type == type);

  factory PaneConfig.fromJson(Map<String, Object?> j) {
    final raw = _string(j, 'type', 'reader');
    final type = _paneTypeNames.entries
        .where((e) => e.value == raw)
        .map((e) => e.key)
        .firstOrNull;
    final plugin = raw.startsWith('plugin:');
    return PaneConfig(
      id: _string(j, 'id', 'pane'),
      type: plugin ? PaneType.plugin : (type ?? PaneType.custom),
      pluginId: plugin ? raw.substring(7) : null,
      customType: !plugin && type == null ? raw : null,
      source: _string(j, 'source', 'main'),
      linkGroup: j['link_group'] as String?,
      layers: [for (final e in _objects(j, 'layers')) LayerConfig.fromJson(e)],
      options: _object(j, 'options'),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': typeName,
    'source': source,
    if (linkGroup != null) 'link_group': linkGroup,
    'layers': [for (final l in layers) l.toJson()],
    'options': options,
  };
}

/// Рабочая область: одна раскладка и список панелей.
class WorkspaceConfig {
  WorkspaceConfig({
    this.version = 1,
    this.layout = const WorkspaceLayoutSpec.single(),
    List<PaneConfig> panes = const [],
  }) : panes = List.unmodifiable(panes);

  final int version;
  final WorkspaceLayoutSpec layout;
  final List<PaneConfig> panes;

  /// Текущая однопанельная раскладка чтения.
  factory WorkspaceConfig.singleReader() => WorkspaceConfig(
    panes: [
      PaneConfig(
        id: 'reader',
        type: PaneType.reader,
        source: 'main',
        linkGroup: 'main',
        layers: [
          LayerConfig(LayerType.text),
          LayerConfig(LayerType.footnotes),
          LayerConfig(LayerType.xrefs),
          LayerConfig(LayerType.strongs),
        ],
      ),
    ],
  );

  factory WorkspaceConfig.fromJson(Map<String, Object?> j) => WorkspaceConfig(
    version: (j['version'] as num? ?? 1).toInt(),
    layout: WorkspaceLayoutSpec.fromJson(_object(j, 'layout')),
    panes: [for (final e in _objects(j, 'panes')) PaneConfig.fromJson(e)],
  );

  Map<String, Object?> toJson() => {
    'version': version,
    'layout': layout.toJson(),
    'panes': [for (final p in panes) p.toJson()],
  };
}
