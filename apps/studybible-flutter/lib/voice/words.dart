/// Пословная разметка фразы для оценочной подсветки нейробэкенда:
/// движок не сообщает позицию слова — её оцениваем по позиции
/// аудио, распределяя длительность пропорционально длине слов
/// с паузами на знаках препинания.
library;

import 'voice_backend.dart' show WordMark;

/// Слово фразы с накопленным весом [cum] (позиция конца слова
/// в «весовых единицах» — по ним переводим долю звучания в слово).
class WSpan {
  const WSpan(this.start, this.end, this.cum);
  final int start, end;
  final double cum;
}

/// Дополнительный вес паузы за знаком препинания (в «символах»).
double _pauseWeight(String w) {
  final last = w.isEmpty ? '' : w[w.length - 1];
  return switch (last) {
    '.' || '!' || '?' || '…' => 6,
    ',' || ';' || ':' || '—' || '»' || '"' => 3,
    _ => 0,
  };
}

/// Разбить фразу на слова с весами: слово весит столько символов,
/// сколько в нём букв (+ пауза за знаком). Смещения — в символах
/// исходного текста, как их ждёт подсветка стиха.
List<WSpan> wordSpans(String text) {
  final out = <WSpan>[];
  var cum = 0.0;
  final re = RegExp(r'\S+');
  for (final m in re.allMatches(text)) {
    cum += m.end - m.start + _pauseWeight(m.group(0)!);
    out.add(WSpan(m.start, m.end, cum));
  }
  return out;
}

/// Слово, звучащее на доле [frac] (0..1) аудиодорожки фразы;
/// null — слов нет или позиция за пределами.
WordMark? wordAt(List<WSpan> spans, String text, double frac) {
  if (spans.isEmpty || frac < 0 || frac > 1) return null;
  final total = spans.last.cum;
  if (total <= 0) return null;
  final at = frac * total;
  for (final s in spans) {
    if (at <= s.cum) {
      return WordMark(s.start, s.end, text.substring(s.start, s.end));
    }
  }
  final last = spans.last;
  return WordMark(last.start, last.end, text.substring(last.start, last.end));
}
