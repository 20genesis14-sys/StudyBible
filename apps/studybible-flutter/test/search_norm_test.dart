/// Нормализация поискового запроса web-моста (lib/search_norm.dart,
/// вынесена из native_bridge_web.dart для тестов) — примеры зеркалят
/// `crates/studybible-core/tests/text.rs::normalize_search`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/search_norm.dart';

void main() {
  group('normSearchQuery (web-порт for_search)', () {
    test('регистр, ё и дореформенные буквы', () {
      expect(normSearchQuery('ИЕГОВА'), 'иегова');
      expect(normSearchQuery('Ёлка ЁЛКА'), 'елка елка');
      expect(
        normSearchQuery('вѣчный ісповѣдую ѳеодосіи'),
        'вечный исповедую феодосии',
      );
      // «й» не сливается с «и».
      expect(normSearchQuery('мой мои'), 'мой мои');
    });

    test('комбинирующая диакритика и мягкий перенос снимаются', () {
      expect(normSearchQuery('миро́'), 'миро');
      expect(normSearchQuery('сло­во'), 'слово');
      expect(normSearchQuery('В начале'), 'в начале');
    });

    test('греческая конечная сигма ς → σ', () {
      expect(normSearchQuery('λογος'), 'λογοσ');
      expect(normSearchQuery('Σς'), 'σσ');
      // ΛΟΓΟΣ и λογος нормализуются одинаково.
      expect(normSearchQuery('λογος'), normSearchQuery('ΛΟΓΟΣ'));
    });

    test('иврит: огласовки снимаются, конечные формы → обычные', () {
      expect(normSearchQuery('בְּרֵאשִׁ֖ית'), 'בראשית');
      expect(normSearchQuery('מֶלֶךְ'), 'מלכ');
      expect(normSearchQuery('שָׁלוֹם'), 'שלומ');
      // Маккеф — разделитель слов.
      expect(normSearchQuery('כָּל־הָאָרֶץ'), 'כל הארצ');
    });
  });

  // Операторы запроса — зеркало crates/studybible-store::search.
  group('parseSearchQuery', () {
    test('слова и операторы', () {
      expect(
        parseSearchQuery('свет земл*'),
        [(kind: 'word', value: 'свет'), (kind: 'prefix', value: 'земл')],
      );
      expect(
        parseSearchQuery('"да будет" све?'),
        [(kind: 'phrase', value: 'да будет'), (kind: 'glob', value: 'све?')],
      );
      // Внутренняя * — glob, не префикс.
      expect(parseSearchQuery('н*е'), [(kind: 'glob', value: 'н*е')]);
      // Незакрытая кавычка — фраза до конца.
      expect(
        parseSearchQuery('"да будет'),
        [(kind: 'phrase', value: 'да будет')],
      );
      // Пунктуация фразы токенизируется.
      expect(
        parseSearchQuery('"сказал Бог:"'),
        [(kind: 'phrase', value: 'сказал бог')],
      );
      expect(parseSearchQuery('   '), isEmpty);
    });
  });

  group('ftsQuery', () {
    test('сборка MATCH', () {
      expect(
        ftsQuery([
          (kind: 'word', value: 'свет'),
          (kind: 'prefix', value: 'земл'),
          (kind: 'phrase', value: 'да будет'),
        ]),
        '"свет" AND "земл"* AND "да будет"',
      );
    });
  });

  group('scanMatch', () {
    const text = 'и сказал бог да будет свет и стал свет';
    test('glob и префикс по токенам (пунктуация срезана)', () {
      expect(
        scanMatch('в начале сотворил бог небо и землю.', [
          (kind: 'glob', value: 'земл?'),
        ]),
        'в начале сотворил бог небо и [землю]',
      );
      expect(
        scanMatch(text, [(kind: 'prefix', value: 'св')]),
        'и сказал бог да будет [свет] и стал [свет]',
      );
      expect(
        scanMatch(text, [(kind: 'glob', value: 'све?')]),
        contains('[свет]'),
      );
    });
    test('AND и фраза', () {
      expect(
        scanMatch(text, [
          (kind: 'phrase', value: 'да будет'),
          (kind: 'word', value: 'стал'),
        ]),
        isNotNull,
      );
      expect(
        scanMatch(text, [(kind: 'phrase', value: 'будет да')]),
        isNull,
      );
      expect(
        scanMatch('земля же была безвидна', [(kind: 'word', value: 'свет')]),
        isNull,
      );
    });
  });
}
