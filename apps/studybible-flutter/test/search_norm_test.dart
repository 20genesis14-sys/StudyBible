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
}
