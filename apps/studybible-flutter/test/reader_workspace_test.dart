import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/workspace/reader_workspace.dart';

Location v(String m, String b, int ch, [int verse = 0]) =>
    Location.verse(moduleId: m, book: b, chapter: ch, verse: verse);

void main() {
  test('go/back/forward — курсор по стеку', () {
    final w = ReaderWorkspace();
    w.go(v('syn', 'GEN', 1));
    w.go(v('syn', 'GEN', 2));
    w.go(v('syn', 'GEN', 3));
    expect(w.canBack, isTrue);
    expect(w.canForward, isFalse);
    expect(w.back()!.chapter, 2);
    expect(w.back()!.chapter, 1);
    expect(w.back(), isNull); // стек исчерпан — дальше «домой»
    expect(w.canBack, isFalse);
    expect(w.forward()!.chapter, 2);
    expect(w.forward()!.chapter, 3);
    expect(w.forward(), isNull);
  });

  test('дубликат текущей позиции не пишется', () {
    final w = ReaderWorkspace();
    w.go(v('syn', 'GEN', 1));
    w.go(v('syn', 'GEN', 1));
    expect(w.depth, 1);
  });

  test('go отсекает «вперёд»-хвост', () {
    final w = ReaderWorkspace();
    w.go(v('syn', 'GEN', 1));
    w.go(v('syn', 'GEN', 2));
    w.back();
    w.go(v('syn', 'EXO', 1));
    expect(w.canForward, isFalse);
    expect(w.depth, 2);
    expect(w.current!.book, 'EXO');
  });

  test('смена перевода на месте — переход (back вернёт перевод)', () {
    final w = ReaderWorkspace();
    w.go(v('syn', 'GEN', 1, 5));
    w.go(v('nwt', 'GEN', 1, 5));
    expect(w.depth, 2);
    expect(w.back()!.moduleId, 'syn');
    expect(w.current!.verse, 5);
  });

  test('лимит 250: старые входы отсекаются с головы', () {
    final w = ReaderWorkspace();
    for (var i = 1; i <= 260; i++) {
      w.go(v('syn', 'GEN', i));
    }
    expect(w.depth, 250);
    expect(w.current!.chapter, 260);
    // Шагов назад ровно 249 — до главы 11.
    var steps = 0;
    while (w.back() != null) {
      steps++;
    }
    expect(steps, 249);
    expect(w.current!.chapter, 11);
  });

  test('json позиции — круг без потерь', () {
    final loc = Location.verse(
      moduleId: 'nwt',
      book: 'PSA',
      chapter: 23,
      verse: 1,
      pane: const {'interleaved': true, 'cmp': 'syn'},
    );
    final rt = Location.fromJson(loc.toJson());
    expect(rt.samePlace(loc), isTrue);
    expect(rt.pane['cmp'], 'syn');
  });
}
