import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/models.dart';
import 'package:studybible/workspace/contributions.dart';

void main() {
  test('встроенные вклады зарегистрированы и упорядочены', () {
    final layers = contributions.ofKind(ContributionKind.layer);
    expect(
      layers.map((c) => c.id).toList(),
      ['layer.compare', 'layer.footnotes', 'layer.xrefs', 'layer.strongs'],
    );
    final presets = contributions.ofKind(ContributionKind.preset);
    expect(presets.map((c) => c.id), ['preset.reading', 'preset.study']);
  });

  test('duplicate id — ошибка, а не тихая перезапись', () {
    final r = ContributionRegistry();
    const c = Contribution(
      id: 'x',
      kind: ContributionKind.layer,
      titleRu: 'a',
      titleEn: 'b',
    );
    r.register(c);
    expect(() => r.register(c), throwsArgumentError);
  });

  test('requires фильтрует по features модуля', () {
    const strongs = Contribution(
      id: 's',
      kind: ContributionKind.layer,
      titleRu: 'a',
      titleEn: 'b',
      requires: ['strongs'],
    );
    ModuleDoc mod([List<String> features = const []]) => ModuleDoc(
      id: 'm',
      title: 'm',
      language: 'ru',
      features: features,
      books: const [],
      chapters: const {},
      verseCounts: const {},
    );
    // Модуль без features (старый): hasFeature — мягко true.
    expect(strongs.availableFor(mod()), isTrue);
    // Модуль с явным списком без strongs — слой недоступен.
    expect(strongs.availableFor(mod(const ['footnotes'])), isFalse);
    expect(strongs.availableFor(mod(const ['strongs'])), isTrue);
  });

  test('неизвестный id — мягкий пропуск', () {
    expect(contributions.resolve('layer.unknown-plugin'), isNull);
  });
}
