import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/userdata_bus.dart';

/// Шина записей пользователя (DECISIONS 18.10.2026, B8): мутации
/// извещают, подписчики сверяют область. Коалиция перечиток живёт
/// на экране чтения — здесь проверяется сама шина.
void main() {
  test('извещение доходит до слушателя с областью мутации', () {
    final bus = UserDataBus();
    final events = <UserDataScope?>[];
    bus.addListener(() => events.add(bus.lastScope));
    bus.changed(module: 'russyn', book: 'gen', chapter: 1);
    expect(events, hasLength(1));
    expect(events.single?.module, 'russyn');
    expect(events.single?.book, 'gen');
    expect(events.single?.chapter, 1);
  });

  test('извещение без координат — область null («перечитать всё»)', () {
    final bus = UserDataBus();
    UserDataScope? got;
    bus.addListener(() => got = bus.lastScope);
    bus.changed();
    expect(got, isNull);
    expect(bus.lastScope, isNull);
  });

  test('частичная область: координаты хранятся как заданы', () {
    final bus = UserDataBus();
    bus.addListener(() {});
    bus.changed(chapter: 3);
    expect(bus.lastScope?.chapter, 3);
    expect(bus.lastScope?.module, isNull);
    expect(bus.lastScope?.book, isNull);
  });

  test('повторные извещения перезаписывают область и доставляются всем', () {
    final bus = UserDataBus();
    var a = 0, b = 0;
    bus.addListener(() => a++);
    bus.addListener(() => b++);
    bus.changed(module: 'x', book: 'gen', chapter: 1);
    bus.changed(module: 'y', book: 'exo', chapter: 2);
    expect(a, 2);
    expect(b, 2);
    expect(bus.lastScope?.module, 'y');
    expect(bus.lastScope?.book, 'exo');
    expect(bus.lastScope?.chapter, 2);
  });

  test('после отписки извещения не доходят', () {
    final bus = UserDataBus();
    var n = 0;
    void listener() => n++;
    bus.addListener(listener);
    bus.changed(module: 'a', book: 'gen', chapter: 1);
    expect(n, 1);
    bus.removeListener(listener);
    bus.changed(module: 'a', book: 'gen', chapter: 2);
    expect(n, 1);
  });
}
