import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/native_bridge_io.dart';
import 'package:studybible/state.dart';

void main() {
  group('Settings.workspaceJson (B10, этап 2)', () {
    // Содержимое — прозрачный канал: Settings его не разбирает,
    // поэтому строка может быть любым (проверяем правдоподобный JSON).
    const blob = '{"panes":["russyn"],"pos":"GEN:1","marker":"ws-roundtrip"}';

    test('load: ключа «workspace» нет → null', () async {
      // FLUTTER_TEST=true → userdata.db во временном каталоге,
      // реальная база пользователя не трогается. Пишем блоб настроек
      // без 'workspace' — предусловие детерминировано.
      await bridgeSettingsSave(
        jsonEncode({'lang': 'ru', 'defaultModule': 'russyn'}),
      );
      final s = Settings();
      await s.load();
      expect(s.workspaceJson, isNull);
      expect(s.lang, 'ru');
    });

    test('roundtrip через UserData: сохранение → загрузка', () async {
      final s = Settings();
      await s.load();
      s.update(() => s.workspaceJson = blob);
      // _save() — fire-and-forget: ждём, пока запись появится в БД
      // (маркер ищем как подстроку — внутри JSON он экранирован).
      var saved = false;
      for (var i = 0; i < 100 && !saved; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        saved =
            (await bridgeSettingsLoad())?.contains('ws-roundtrip') ?? false;
      }
      expect(saved, isTrue, reason: 'workspace не записался в UserData');

      final s2 = Settings();
      await s2.load();
      expect(s2.workspaceJson, blob);

      // Чистим за собой: temp-база общая на весь прогон тестов.
      s2.update(() => s2.workspaceJson = null);
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final raw = await bridgeSettingsLoad();
        if (raw == null || !raw.contains('ws-roundtrip')) break;
      }
    });
  });
}
