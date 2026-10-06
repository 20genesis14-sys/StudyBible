import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/voice/pronounce.dart';
import 'package:studybible/voice/voice_pack.dart';
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
}
