/// Готовые пресеты рабочей области (ADR 0014; DECISIONS 18.10.2026,
/// этап 1 B10): постоянные значения [WorkspaceConfig], из которых
/// проводка (следующий этап, пока не написана) делает стартовые
/// раскладки и пункты меню «раскладки».
///
/// «Сравнение» — все панели привязаны к основной (`link_group: 'main'`)
/// и листают вместе; «Места» — все панели независимы (`link_group`
/// отсутствует), каждый просмотр листается сам по себе.
///
/// Пресеты — константы модели, а не готовый JSON: при сохранении в
/// настройки они сериализуются [encodeWorkspace] точно так же, как
/// пользовательские конфигурации.
library;

import 'package:studybible/workspace/workspace_model.dart';

/// «Чтение»: одна панель — зеркало `WorkspaceConfig.singleReader()`
/// с позицией GEN 1:1.
final WorkspaceConfig kPresetReading = WorkspaceConfig.singleReader().withPane(
  0,
  WorkspaceConfig.singleReader().panes.first.copyWith(
    book: 'GEN',
    chapter: 1,
    verse: 1,
  ),
);

/// «Сравнение»: две панели чтения рядом, обе следуют за основной —
/// синхронный листатель для сличения переводов.
///
/// `source: 'russyn'` второй панели — плейсхолдер модуля: проводка
/// заменит его на реально установленный второй перевод (fallback —
/// оставить, панель без модуля покажет «модуль не найден»).
final WorkspaceConfig kPresetComparing = WorkspaceConfig(
  layout: const WorkspaceLayoutSpec.splitHorizontal(ratio: 0.5),
  activePane: 0,
  panes: [
    PaneConfig(
      id: 'reader',
      type: PaneType.reader,
      source: 'main',
      linkGroup: 'main',
      book: 'GEN',
      chapter: 1,
      verse: 1,
      layers: [LayerConfig(LayerType.text)],
    ),
    PaneConfig(
      id: 'second',
      type: PaneType.reader,
      source: 'russyn',
      linkGroup: 'main',
      book: 'GEN',
      chapter: 1,
      verse: 1,
      layers: [LayerConfig(LayerType.text)],
    ),
  ],
);

/// «Места»: две панели чтения без привязки (`link_group` нет) —
/// независимые закладки-места, каждая листается сама.
final WorkspaceConfig kPresetPlaces = WorkspaceConfig(
  layout: const WorkspaceLayoutSpec.splitHorizontal(ratio: 0.5),
  activePane: 0,
  panes: [
    PaneConfig(
      id: 'place-1',
      type: PaneType.reader,
      source: 'main',
      book: 'GEN',
      chapter: 1,
      verse: 1,
      layers: [LayerConfig(LayerType.text)],
    ),
    PaneConfig(
      id: 'place-2',
      type: PaneType.reader,
      source: 'main',
      book: 'GEN',
      chapter: 1,
      verse: 1,
      layers: [LayerConfig(LayerType.text)],
    ),
  ],
);

/// Пресеты для выбора в UI: `id` — стабильный ключ (например, для
/// «последний выбранный пресет» в настройках), имена — для меню.
final List<({String id, String nameRu, String nameEn, WorkspaceConfig config})>
kWorkspacePresets = [
  (id: 'reading', nameRu: 'Чтение', nameEn: 'Reading', config: kPresetReading),
  (
    id: 'comparing',
    nameRu: 'Сравнение',
    nameEn: 'Comparing',
    config: kPresetComparing,
  ),
  (id: 'places', nameRu: 'Места', nameEn: 'Places', config: kPresetPlaces),
];
