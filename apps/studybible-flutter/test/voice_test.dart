import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/state.dart' show settings;
import 'package:studybible/voice/phrases.dart';
import 'package:studybible/voice/pronounce.dart';
import 'package:studybible/voice/voice_pack.dart';
import 'package:studybible/voice/voice_pick.dart';
import 'package:studybible/voice/voice_registry_io.dart';
import 'package:studybible/voice/wav.dart';
import 'package:studybible/voice/words.dart';

void main() {
  group('wavFromPcm', () {
    test('заголовок RIFF/WAVE и длина данных', () {
      final wav = wavFromPcm(Float32List.fromList([0.0, 0.5, -0.5]), 22050);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(wav.length, 44 + 3 * 2);
      // Частота и байт/сек — little-endian.
      final rate = ByteData.sublistView(wav).getUint32(24, Endian.little);
      expect(rate, 22050);
    });

    test('float → PCM16 с насыщением по краям', () {
      final wav = wavFromPcm(Float32List.fromList([1.5, -1.5, 0.0]), 16000);
      final d = ByteData.sublistView(wav);
      expect(d.getInt16(44, Endian.little), 32767);
      expect(d.getInt16(46, Endian.little), -32767);
      expect(d.getInt16(48, Endian.little), 0);
    });
  });

  group('wordSpans/wordAt (оценочная подсветка)', () {
    test('разбивка на слова со смещениями в тексте', () {
      final w = wordSpans('В начале Бог создал');
      expect(w.length, 4);
      expect(w[0].start, 0);
      expect(w[0].end, 1); // «В»
      expect(w[1].start, 2);
      expect(w[1].end, 8); // «начале»
    });

    test('знаки препинания увеличивают вес (пауза)', () {
      final a = wordSpans('земля была');
      final b = wordSpans('земля, была');
      // Запятая добавляет паузу — суммарный вес больше.
      expect(b.last.cum, greaterThan(a.last.cum));
    });

    test('wordAt: начало и конец фразы', () {
      const t = 'раз два три четыре';
      final w = wordSpans(t);
      expect(wordAt(w, t, 0.0)!.word, 'раз');
      expect(wordAt(w, t, 0.99)!.word, 'четыре');
      expect(wordAt(w, t, -0.1), isNull);
    });

    test('wordAt движется по весам слов', () {
      const t = 'a bbb cc';
      final w = wordSpans(t); // веса 1,3,2 → границы 1,4,6
      expect(wordAt(w, t, 0.1)!.word, 'a');
      expect(wordAt(w, t, 0.4)!.word, 'bbb');
      expect(wordAt(w, t, 0.9)!.word, 'cc');
    });

    test('пустая строка и один пунктуатор', () {
      expect(wordSpans(''), isEmpty);
      expect(wordAt(wordSpans(''), '', 0.5), isNull);
      // «,» — слово из одного знака: вес 1 + пауза 3.
      final w = wordSpans(',');
      expect(w, hasLength(1));
      expect(w.single.cum, 4);
      // frac за пределами 0..1 → null.
      expect(wordAt(w, ',', 1.5), isNull);
    });

    test('одно слово без знаков', () {
      final w = wordSpans('свет');
      expect(w, hasLength(1));
      expect(wordAt(w, 'свет', 0.5)!.word, 'свет');
      expect(wordAt(w, 'свет', 1.0)!.word, 'свет');
    });
  });

  group('VoicePack — разбор метаданных', () {
    test('язык из piper-конфига (language.code)', () {
      expect(
        packLanguage('vits-piper-x', {
          'language': {'code': 'ru_RU'},
        }),
        'ru',
      );
    });

    test('язык из имени папки без конфига', () {
      expect(packLanguage('vits-piper-en_US-amy', {}), 'en');
      expect(packLanguage('plain', {}), '');
    });

    test('дикторы из num_speakers и speaker_id_map', () {
      expect(packSpeakers({'num_speakers': 3}), 3);
      expect(packSpeakers({'speaker_id_map': {'a': 0, 'b': 1}}), 2);
      expect(packSpeakers({}), 1);
    });

    test('voiceForLanguage: явный выбор > первый годный', () {
      VoicePack p(String id, String lang, {List<String> i = const []}) =>
          VoicePack(
            id: id,
            dir: '/v/$id',
            name: id,
            language: lang,
            model: '/v/$id/m.onnx',
            tokens: '/v/$id/tokens.txt',
            dataDir: '/v/$id/espeak-ng-data',
            issues: i,
          );
      final packs = [p('a', 'ru'), p('b', 'ru'), p('c', 'en')];
      expect(voiceForLanguage(packs, 'ru-RU', '')!.id, 'a');
      expect(voiceForLanguage(packs, 'ru-RU', 'ru:b')!.id, 'b');
      expect(voiceForLanguage(packs, 'en-US', '')!.id, 'c');
      expect(voiceForLanguage(packs, 'he-IL', ''), isNull);
      // Негодный пакет не выбирается.
      expect(
        voiceForLanguage([p('x', 'ru', i: ['нет tokens.txt'])], 'ru', ''),
        isNull,
      );
    });
  });

  group('scanVoices', () {
    test('полный пакет piper + voice.json + негодный сосед', () {
      final root = Directory.systemTemp.createTempSync('voices');
      addTearDown(() => root.deleteSync(recursive: true));
      final pack = Directory('${root.path}/vits-piper-ru_RU-dmitri')
        ..createSync();
      File('${pack.path}/ru_RU-dmitri-medium.onnx').writeAsBytesSync([0]);
      File('${pack.path}/tokens.txt').writeAsStringSync('x');
      File('${pack.path}/ru_RU-dmitri-medium.onnx.json')
          .writeAsStringSync('{"language":{"code":"ru_RU"},"num_speakers":1}');
      Directory('${pack.path}/espeak-ng-data').createSync();
      File('${pack.path}/voice.json')
          .writeAsStringSync('{"name":"Дмитрий"}');
      // Негодный пакет: только модель.
      final bad = Directory('${root.path}/broken')..createSync();
      File('${bad.path}/m.onnx').writeAsBytesSync([0]);

      final packs = scanVoices(root.path);
      expect(packs, hasLength(2));
      final good = packs.firstWhere((p) => p.id.contains('dmitri'));
      expect(good.usable, isTrue);
      expect(good.language, 'ru');
      expect(good.name, 'Дмитрий');
      final broken = packs.firstWhere((p) => p.id == 'broken');
      expect(broken.usable, isFalse);
      expect(broken.issues, isNotEmpty);
    });

    test('общий espeak-ng-data в корне voices закрывает пробел пакета', () {
      final root = Directory.systemTemp.createTempSync('voices');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/espeak-ng-data').createSync();
      final pack = Directory('${root.path}/vits-piper-en_US-amy')
        ..createSync();
      File('${pack.path}/m.onnx').writeAsBytesSync([0]);
      File('${pack.path}/tokens.txt').writeAsStringSync('x');

      final packs = scanVoices(root.path);
      expect(packs.single.usable, isTrue);
      expect(packs.single.language, 'en');
    });

    test('папка без onnx не голос', () {
      final root = Directory.systemTemp.createTempSync('voices');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/junk').createSync();
      File('${root.path}/junk/readme.txt').writeAsStringSync('x');
      expect(scanVoices(root.path), isEmpty);
    });

    test('пустой каталог голосов — пустой список', () {
      final root = Directory.systemTemp.createTempSync('voices');
      addTearDown(() => root.deleteSync(recursive: true));
      expect(scanVoices(root.path), isEmpty);
    });

    test('нет tokens.txt / нет espeak-ng-data — issues с причиной', () {
      final root = Directory.systemTemp.createTempSync('voices');
      addTearDown(() => root.deleteSync(recursive: true));
      final noTok = Directory('${root.path}/vits-piper-en_US-no-tokens')
        ..createSync();
      File('${noTok.path}/m.onnx').writeAsBytesSync([0]);
      Directory('${noTok.path}/espeak-ng-data').createSync();
      final noData = Directory('${root.path}/vits-piper-ru_RU-no-data')
        ..createSync();
      File('${noData.path}/m.onnx').writeAsBytesSync([0]);
      File('${noData.path}/tokens.txt').writeAsStringSync('x');

      final packs = scanVoices(root.path);
      final a = packs.firstWhere((p) => p.id.contains('no-tokens'));
      expect(a.usable, isFalse);
      expect(a.issues, contains('нет tokens.txt'));
      expect(a.issues, isNot(contains('нет espeak-ng-data')));
      final b = packs.firstWhere((p) => p.id.contains('no-data'));
      expect(b.usable, isFalse);
      expect(b.issues, contains('нет espeak-ng-data'));
      expect(b.issues, isNot(contains('нет tokens.txt')));
    });

    test('битый .onnx.json — пакет негоден с понятной причиной', () {
      final root = Directory.systemTemp.createTempSync('voices');
      addTearDown(() => root.deleteSync(recursive: true));
      final pack = Directory('${root.path}/vits-piper-ru_RU-bad')
        ..createSync();
      File('${pack.path}/m.onnx').writeAsBytesSync([0]);
      File('${pack.path}/m.onnx.json').writeAsStringSync('{не json');
      File('${pack.path}/tokens.txt').writeAsStringSync('x');
      Directory('${pack.path}/espeak-ng-data').createSync();

      final p = scanVoices(root.path).single;
      expect(p.usable, isFalse);
      expect(
        p.issues.where((i) => i.contains('битый')),
        isNotEmpty,
        reason: 'issues: ${p.issues}',
      );
    });

    test('tokens.txt на уровень глубже находится', () {
      final root = Directory.systemTemp.createTempSync('voices');
      addTearDown(() => root.deleteSync(recursive: true));
      final pack = Directory('${root.path}/vits-piper-ru_RU-nested')
        ..createSync();
      File('${pack.path}/m.onnx').writeAsBytesSync([0]);
      final sub = Directory('${pack.path}/sub')..createSync();
      File('${sub.path}/tokens.txt').writeAsStringSync('x');
      Directory('${sub.path}/espeak-ng-data').createSync();

      final p = scanVoices(root.path).single;
      expect(p.usable, isTrue);
      expect(p.tokens, endsWith('tokens.txt'));
    });
  });

  group('pickVoiceBackend', () {
    final savedEngine = settings.voiceEngine;
    tearDown(() => settings.voiceEngine = savedEngine);

    test('neural без пакета под язык — ошибка с подсказкой', () async {
      settings.voiceEngine = 'neural';
      // 'he' — пакета точно нет (в реальных voices только ru_*).
      final r = await pickVoiceBackend('he-IL');
      expect(r.backend, isNull);
      expect(r.error, contains('Нет голосового пакета'));
      expect(r.error, contains('he-IL'));
    });

    test('auto без пакета — молчаливый фоллбэк на системный', () async {
      settings.voiceEngine = 'auto';
      final r = await pickVoiceBackend('he-IL');
      // Пакета нет → системный бэкенд; в тестовом раннере flutter_tts
      // без движка → его ошибка (не «нет пакета»).
      expect(r.backend, isNull);
      expect(r.error, isNotNull);
      expect(r.error, isNot(contains('голосового пакета')));
    });

    test('system: ошибка TTS-движка возвращается текстом', () async {
      settings.voiceEngine = 'system';
      final r = await pickVoiceBackend('ru-RU');
      expect(r.backend, isNull);
      expect(r.error, contains('Синтез речи недоступен'));
    });
  });

  group('PronounceDict — подмена только для синтеза', () {
    test('целые слова, подстроки не трогаются', () {
      const d = PronounceDict.raw({'иов': 'ио́в'});
      expect(d.apply('книга Иова и Иов'), 'книга Иова и Ио́в');
      expect(d.apply('иова иов'), 'иова ио́в');
    });

    test('заглавная буква сохраняется', () {
      const d = PronounceDict.raw({'иов': 'ио́в'});
      expect(d.apply('Иов страдал'), 'Ио́в страдал');
    });

    test('pronounce.tsv переопределяет базовый словарь', () {
      final dir = Directory.systemTemp.createTempSync('voice');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/pronounce.tsv').writeAsStringSync(
        '# комментарий\nиов\tи́ов-лучше\nбез-таба\n\tпустой ключ\n',
      );
      final d = PronounceDict.merged(dir.path);
      // Запись файла перекрыла базовую.
      expect(d.apply('Иов'), 'И́ов-лучше');
      // Остальная базовая лексика на месте.
      expect(d.apply('Назарет'), 'Назаре́т');
      // Строки без таба проигнорированы.
      expect(d.apply('без-таба'), 'без-таба');
    });

    test('без файла — только базовый словарь', () {
      final dir = Directory.systemTemp.createTempSync('voice');
      addTearDown(() => dir.deleteSync(recursive: true));
      final d = PronounceDict.merged(dir.path);
      expect(d.apply('Синай'), 'Сина́й');
      expect(d.apply('обычный текст'), 'обычный текст');
    });
  });

  group('splitPhrases (паузы нейрочтения)', () {
    test('разделители и их паузы; знак остаётся в фразе', () {
      final p = splitPhrases('а, б; в: г. д! е? ж');
      expect(p.map((x) => x.text), ['а,', ' б;', ' в:', ' г.', ' д!', ' е?', ' ж']);
      expect(p.map((x) => x.pauseMs), [120, 220, 220, 350, 350, 350, 0]);
    });

    test('последняя фраза — пауза 0 даже со знаком', () {
      final p = splitPhrases('да будет свет.');
      expect(p.single.pauseMs, 0);
      expect(p.single.text, 'да будет свет.');
    });

    test('подряд идущие разделители — одна фраза («!?», «…»)', () {
      final p = splitPhrases('что?! ну...');
      expect(p.length, 2);
      expect(p[0].text, 'что?!');
      expect(p[0].pauseMs, 350);
      expect(p[1].text, ' ну...');
      expect(p[1].pauseMs, 0);
    });

    test('пустые куски отбрасываются, текст без знаков — одна фраза', () {
      expect(splitPhrases(''), isEmpty);
      expect(splitPhrases('   '), isEmpty);
      expect(splitPhrases('просто текст').single.text, 'просто текст');
    });

    test('один пунктуатор — одна фраза с паузой 0', () {
      expect(splitPhrases('?').single.text, '?');
      expect(splitPhrases('?').single.pauseMs, 0);
      expect(splitPhrases('?!').single.text, '?!');
    });

    test('«— ,» и многоточие как часть фразы', () {
      // '—' не разделитель, ',' разделитель: вся строка — одна фраза.
      final p = splitPhrases('— ,');
      expect(p.single.text, '— ,');
      expect(p.single.pauseMs, 0);
      // Многоточие внутри фразы не режет её.
      final e = splitPhrases('ждал… и дождался.');
      expect(e.single.text, 'ждал… и дождался.');
    });

    test('одно слово без финальной пунктуации', () {
      final p = splitPhrases('свет');
      expect(p.single.text, 'свет');
      expect(p.single.pauseMs, 0);
    });
  });
}
