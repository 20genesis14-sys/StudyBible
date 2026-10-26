import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/workspace/workspace_model.dart';
import 'package:studybible/workspace/workspace_presets.dart';

void main() {
  group('пресеты рабочей области', () {
    test('список пресетов полон', () {
      expect(kWorkspacePresets, hasLength(3));
      expect(kWorkspacePresets.map((p) => p.id), [
        'reading',
        'comparing',
        'places',
      ]);
      for (final p in kWorkspacePresets) {
        expect(p.nameRu, isNotEmpty);
        expect(p.nameEn, isNotEmpty);
      }
    });

    test('чтение — зеркало singleReader с позицией GEN 1:1', () {
      final base = WorkspaceConfig.singleReader();
      expect(kPresetReading.layout.type, WorkspaceLayoutType.single);
      expect(kPresetReading.panes.single.source, 'main');
      expect(kPresetReading.panes.single.linkGroup, 'main');
      expect(
        kPresetReading.panes.single.layers.map((l) => l.type),
        base.panes.single.layers.map((l) => l.type),
      );
      expect(kPresetReading.panes.single.book, 'GEN');
      expect(kPresetReading.panes.single.chapter, 1);
      expect(kPresetReading.panes.single.verse, 1);
    });

    test('сравнение — обе панели привязаны к основной', () {
      expect(kPresetComparing.layout.type, WorkspaceLayoutType.splitHorizontal);
      expect(kPresetComparing.layout.ratio, closeTo(0.5, 0.001));
      expect(kPresetComparing.activePane, 0);
      expect(kPresetComparing.panes, hasLength(2));
      for (final pane in kPresetComparing.panes) {
        expect(pane.type, PaneType.reader);
        expect(pane.linkGroup, 'main');
        expect(pane.book, 'GEN');
        expect(pane.chapter, 1);
        expect(pane.verse, 1);
      }
      expect(kPresetComparing.panes[0].source, 'main');
      expect(kPresetComparing.panes[1].source, 'russyn');
    });

    test('места — обе панели независимы', () {
      expect(kPresetPlaces.layout.type, WorkspaceLayoutType.splitHorizontal);
      expect(kPresetPlaces.panes, hasLength(2));
      for (final pane in kPresetPlaces.panes) {
        expect(pane.type, PaneType.reader);
        expect(pane.linkGroup, isNull);
        expect(pane.followsMain, isFalse);
        expect(pane.book, 'GEN');
        expect(pane.chapter, 1);
        expect(pane.verse, 1);
      }
    });

    test('каждый пресет проходит JSON roundtrip без потерь', () {
      for (final preset in kWorkspacePresets) {
        final decoded = WorkspaceConfig.fromJson(
          jsonDecode(jsonEncode(preset.config.toJson()))
              as Map<String, Object?>,
        );
        expect(decoded.toJson(), preset.config.toJson(), reason: preset.id);
      }
    });
  });

  group('позиции панелей в модели', () {
    test('старый снимок без новых ключей даёт умолчания GEN/1/0 и 0', () {
      final w = WorkspaceConfig.fromJson({
        'version': 1,
        'layout': {'type': 'single'},
        'panes': [
          {
            'id': 'reader',
            'type': 'reader',
            'source': 'main',
            'link_group': 'main',
            'layers': [
              {'type': 'text'},
            ],
          },
        ],
      });

      expect(w.activePane, 0);
      final pane = w.panes.single;
      expect(pane.book, 'GEN');
      expect(pane.chapter, 1);
      expect(pane.verse, 0);
      // Обратно записываются новые ключи.
      expect(w.toJson()['activePane'], 0);
      expect(w.panes.single.toJson()['book'], 'GEN');
      expect(w.panes.single.toJson()['chapter'], 1);
      expect(w.panes.single.toJson()['verse'], 0);
    });

    test('новый снимок читает активную панель и позиции', () {
      final w = WorkspaceConfig.fromJson({
        'version': 1,
        'layout': {'type': 'split_horizontal', 'ratio': 0.5},
        'activePane': 1,
        'panes': [
          {
            'id': 'a',
            'type': 'reader',
            'book': 'PSA',
            'chapter': 23,
            'verse': 4,
          },
          {'id': 'b', 'type': 'reader', 'book': 'JHN', 'chapter': 3},
        ],
      });

      expect(w.activePane, 1);
      expect(w.panes[0].book, 'PSA');
      expect(w.panes[0].chapter, 23);
      expect(w.panes[0].verse, 4);
      expect(w.panes[1].book, 'JHN');
      expect(w.panes[1].chapter, 3);
      expect(w.panes[1].verse, 0);
    });

    test('copyWith меняет позицию, источник и очищает linkGroup', () {
      final pane = WorkspaceConfig.singleReader().panes.first;
      final moved = pane.copyWith(book: 'ISA', chapter: 53, verse: 5);
      expect(moved.book, 'ISA');
      expect(moved.chapter, 53);
      expect(moved.verse, 5);
      expect(moved.source, 'main');
      expect(moved.linkGroup, 'main');

      final unlinked = pane.copyWith(linkGroup: null);
      expect(unlinked.linkGroup, isNull);

      final relinked = pane.copyWith(linkGroup: 'side', source: 'russyn');
      expect(relinked.linkGroup, 'side');
      expect(relinked.source, 'russyn');
      // Оригинал неизменен (иммутабельность).
      expect(pane.book, 'GEN');
      expect(pane.linkGroup, 'main');
    });

    test('withPane заменяет панель по индексу, остальное сохраняет', () {
      final w = kPresetComparing;
      final moved = w.withPane(
        1,
        w.panes[1].copyWith(book: 'MRK', chapter: 2, verse: 1),
      );

      expect(moved.layout, same(w.layout));
      expect(moved.activePane, w.activePane);
      expect(moved.panes, hasLength(2));
      expect(moved.panes[0], same(w.panes[0]));
      expect(moved.panes[1].book, 'MRK');
      expect(moved.panes[1].chapter, 2);
      expect(moved.panes[1].verse, 1);
      // Исходная конфигурация не изменилась.
      expect(w.panes[1].book, 'GEN');

      expect(() => w.withPane(2, w.panes[0]), throwsRangeError);
      expect(() => w.withPane(-1, w.panes[0]), throwsRangeError);
    });
  });

  group('encodeWorkspace/decodeWorkspace', () {
    test('строки настройки переживают encode/decode', () {
      for (final preset in kWorkspacePresets) {
        final raw = encodeWorkspace(preset.config);
        expect(raw, isNotNull, reason: preset.id);
        final decoded = decodeWorkspace(raw);
        expect(decoded, isNotNull, reason: preset.id);
        expect(decoded!.toJson(), preset.config.toJson(), reason: preset.id);
      }
    });

    test('мусор и null дают null, а не исключение', () {
      expect(decodeWorkspace(null), isNull);
      expect(decodeWorkspace(''), isNull);
      expect(decodeWorkspace('not json {'), isNull);
      expect(decodeWorkspace('[1, 2, 3]'), isNull);
      expect(decodeWorkspace('"just a string"'), isNull);
    });
  });
}
