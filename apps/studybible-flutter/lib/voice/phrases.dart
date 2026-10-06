/// Деление стиха на фразы для нейробэкенда (ADR 0017 «Фронтенд
/// языка»): между фразами вставляется тишина — VITS без этого
/// проглатывает паузы на знаках препинания.
///
/// Фраза включает свой завершающий знак (он задаёт интонацию),
/// паузу несёт следующий за фразой знак; у последней фразы пауза 0.
library;

/// Пауза после фразы по завершающему знаку (мс).
const pauseComma = 120;
const pauseClause = 220;
const pauseSentence = 350;

/// Знаки-разделители и их паузы.
int _pauseAfter(String ch) => switch (ch) {
  ',' => pauseComma,
  ';' || ':' => pauseClause,
  '.' || '!' || '?' => pauseSentence,
  _ => 0,
};

/// Фразы стиха с паузами после них. Пустые куски отбрасываются;
/// мусорные разделители в начале («, текст») прилипают к своей
/// фразе — синтезу так спокойнее.
List<({String text, int pauseMs})> splitPhrases(String text) {
  final out = <({String text, int pauseMs})>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final pause = _pauseAfter(text[i]);
    if (pause == 0) continue;
    // Многоточие «…» и «!?» — одна фраза: склеиваемые подряд
    // разделители не режут фразу дважды.
    var j = i;
    while (j + 1 < text.length && _pauseAfter(text[j + 1]) != 0) {
      j++;
    }
    final piece = text.substring(start, j + 1);
    if (piece.trim().isNotEmpty) {
      out.add((text: piece, pauseMs: _pauseAfter(text[j])));
    }
    start = j + 1;
    i = j;
  }
  final tail = text.substring(start);
  if (out.isEmpty && tail.trim().isEmpty) return const [];
  if (tail.trim().isNotEmpty) out.add((text: tail, pauseMs: 0));
  if (out.isNotEmpty) {
    // Пауза последней фразы не нужна — конец стиха молчит сам.
    out[out.length - 1] = (text: out.last.text, pauseMs: 0);
  }
  return out;
}
