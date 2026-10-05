import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/workspace/workspace_model.dart';

void main() {
  test('singleReader описывает текущую однопанельную раскладку', () {
    final w = WorkspaceConfig.singleReader();
    expect(w.version, 1);
    expect(w.layout.type, WorkspaceLayoutType.single);
    expect(w.panes, hasLength(1));

    final pane = w.panes.single;
    expect(pane.id, 'reader');
    expect(pane.type, PaneType.reader);
    expect(pane.source, 'main');
    expect(pane.linkGroup, 'main');
    expect(pane.hasLayer(LayerType.text), isTrue);
    expect(pane.hasLayer(LayerType.footnotes), isTrue);
    expect(pane.hasLayer(LayerType.xrefs), isTrue);
    expect(pane.hasLayer(LayerType.strongs), isTrue);
  });

  test('WorkspaceConfig проходит JSON roundtrip', () {
    final w = WorkspaceConfig(
      layout: const WorkspaceLayoutSpec.splitHorizontal(ratio: 0.62),
      panes: [
        PaneConfig(
          id: 'reader',
          type: PaneType.reader,
          linkGroup: 'main',
          layers: [
            LayerConfig(LayerType.text),
            LayerConfig(
              LayerType.secondTranslation,
              options: {'mode': 'inline', 'module': 'engwebp'},
            ),
          ],
        ),
        PaneConfig(
          id: 'dict',
          type: PaneType.plugin,
          pluginId: 'strongs',
          source: 'strongs',
        ),
      ],
    );

    final decoded = WorkspaceConfig.fromJson(
      jsonDecode(jsonEncode(w.toJson())) as Map<String, Object?>,
    );

    expect(decoded.layout.type, WorkspaceLayoutType.splitHorizontal);
    expect(decoded.layout.ratio, closeTo(0.62, 0.001));
    expect(decoded.panes, hasLength(2));
    expect(decoded.panes[1].type, PaneType.plugin);
    expect(decoded.panes[1].typeName, 'plugin:strongs');
    expect(decoded.toJson(), w.toJson());
  });

  test('неизвестные типы сохраняются как custom', () {
    final w = WorkspaceConfig.fromJson({
      'version': 1,
      'layout': {'type': 'future_layout'},
      'panes': [
        {
          'id': 'future',
          'type': 'future_pane',
          'layers': [
            {
              'type': 'future_layer',
              'options': {'x': 1},
            },
          ],
        },
      ],
    });

    final pane = w.panes.single;
    expect(w.layout.type, WorkspaceLayoutType.single);
    expect(pane.type, PaneType.custom);
    expect(pane.typeName, 'future_pane');
    expect(pane.layers.single.type, LayerType.custom);
    expect(pane.layers.single.typeName, 'future_layer');
    expect(w.toJson()['panes'], isNotEmpty);
  });
}
