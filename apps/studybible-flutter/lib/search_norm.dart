/// Нормализация поискового запроса — лёгкий аналог
/// `core::normalize::for_search` для web-моста (сопоставляется со
/// встроенной `fts` модуля по `meta.norm_version`, ADR 0016 п. 11).
/// Вынесена из native_bridge_web.dart ради юнит-тестов: сам мост
/// доступен только в браузере.
///
/// «2» — конечные буквы иврита, маккеф → пробел, ς→σ.
library;

/// Версия правил нормализации, с которой сопоставляется встроенная
/// `fts` модуля (`meta.norm_version`, ADR 0016 п. 11); «2» — конечные
/// буквы иврита, маккеф → пробел, ς→σ.
const String normVersion = '2';

/// Нормализация текста стиха для фоновой `fts` в веб-мосте —
/// те же правила, что и для запроса (`normSearchQuery`); разбиение
/// на слова и пунктуацию делает токенизатор `unicode61`.
String normForIndex(String s) => normSearchQuery(s);

/// Нормализация запроса под колонку `fts.norm`: регистр, ё→е,
/// дореформенные буквы, снятие combining-диакритики, конечные формы
/// иврита, маккеф → пробел, конечная сигма → σ.
///
/// В отличие от Rust-ядра не делает NFD: прекомпонованные буквы с
/// диакритикой (é, ό) остаются как есть — см. OPEN-QUESTIONS.
String normSearchQuery(String s) {
  final b = StringBuffer();
  for (final c in s.toLowerCase().split('')) {
    switch (c) {
      case 'ё':
        b.write('е');
      case 'ѣ':
        b.write('е');
      case 'і':
        b.write('и');
      case 'ѳ':
        b.write('ф');
      case 'ѵ':
        b.write('и');
      // Конечные формы иврита → обычные буквы.
      case 'ך':
        b.write('כ');
      case 'ם':
        b.write('מ');
      case 'ן':
        b.write('נ');
      case 'ף':
        b.write('פ');
      case 'ץ':
        b.write('צ');
      // Маккеф — разделитель слов.
      case '־':
        b.write(' ');
      // Конечная сигма → обычная (Σ уже даёт σ).
      case 'ς':
        b.write('σ');
      default:
        b.write(c);
    }
  }
  // Combining-диапазоны (ударения, огласовки) снимаем.
  return b.toString().replaceAll(
    RegExp('[\\u0300-\\u036F\\u0483-\\u0489\\u0591-\\u05BD\\u0610-\\u061A'
        '\\u064B-\\u065F\\u0670\\u1AB0-\\u1AFF\\u1DC0-\\u1DFF'
        '\\u20D0-\\u20FF\\uFE20-\\uFE2F\\u00AD\\u05BF\\u05C1\\u05C2'
        '\\u05C4\\u05C5\\u05C7]'),
    '',
  );
}
