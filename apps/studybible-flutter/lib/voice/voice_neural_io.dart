/// Бэкенд `neural`: офлайн-синтез VITS/Piper через sherpa_onnx.
///
/// Генерация — в отдельном изоляте (синтез стиха сотни мс, на
/// UI-изоляте замораживал бы прокрутку). Готовое аудио играет
/// audioplayers: точная пауза/продолжение внутри стиха, позиция
/// воспроизведения даёт оценочные пословные метки.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../native_bridge_io.dart' show bridgeAccentInit, bridgeAccentText;
import '../state.dart' show settings;
import 'phrases.dart';
import 'pronounce.dart';
import 'voice_backend.dart';
import 'voice_pack.dart';
import 'wav.dart';
import 'words.dart';

/// Синтезированный клип: WAV-байты и длительность.
class _Clip {
  const _Clip(this.wav, this.duration);
  final Uint8List wav;
  final Duration duration;
}

/// Точка входа изолята синтеза: `init` создаёт OfflineTts,
/// `gen` синтезирует текст → PCM float32 (TransferableTypedData),
/// `close` освобождает движок и гасит изолят.
void _ttsIsolate(SendPort toMain) {
  final recv = ReceivePort();
  // Первое сообщение — порт изолята (id=-1), дальше ответы по id.
  toMain.send({'id': -1, 'port': recv.sendPort});
  sherpa.OfflineTts? tts;
  recv.listen((raw) {
    final m = raw as Map;
    final id = m['id'] as int;
    switch (m['cmd']) {
      case 'init':
        try {
          sherpa.initBindings();
          tts = sherpa.OfflineTts(
            sherpa.OfflineTtsConfig(
              model: sherpa.OfflineTtsModelConfig(
                vits: sherpa.OfflineTtsVitsModelConfig(
                  model: m['model'] as String,
                  lexicon: '',
                  tokens: m['tokens'] as String,
                  dataDir: m['dataDir'] as String,
                ),
                numThreads: 2,
                provider: 'cpu',
              ),
              maxNumSenetences: 1,
            ),
          );
          toMain.send({'id': id, 'ok': true});
        } catch (e) {
          toMain.send({'id': id, 'ok': false, 'error': '$e'});
        }
      case 'gen':
        try {
          // Фразы с паузами (ADR 0017): каждая синтезируется отдельно,
          // между ними — тишина нужной длины; итог — один PCM.
          final parts =
              (m['phrases'] as List).cast<Map>().toList(growable: false);
          final chunks = <Float32List>[];
          var rate = 0;
          var total = 0;
          final silences = <int>[];
          for (final (i, p) in parts.indexed) {
            final a = tts!.generate(
              text: p['t'] as String,
              sid: m['sid'] as int,
              speed: m['speed'] as double,
            );
            rate = a.sampleRate;
            chunks.add(a.samples);
            total += a.samples.length;
            final pauseMs = p['p'] as int;
            if (pauseMs > 0 && i < parts.length - 1) {
              final n = a.sampleRate * pauseMs ~/ 1000;
              silences.add(n);
              total += n;
            } else {
              silences.add(0);
            }
          }
          final pcm = Float32List(total);
          var off = 0;
          for (final (i, c) in chunks.indexed) {
            pcm.setRange(off, off + c.length, c);
            off += c.length + silences[i]; // нули — уже тишина
          }
          toMain.send({
            'id': id,
            'ok': true,
            'rate': rate,
            'pcm': TransferableTypedData.fromList([pcm]),
          });
        } catch (e) {
          toMain.send({'id': id, 'ok': false, 'error': '$e'});
        }
      case 'close':
        tts?.free();
        recv.close();
    }
  });
}

class NeuralVoiceBackend extends VoiceBackend {
  NeuralVoiceBackend(this.pack);

  final VoicePack pack;

  Isolate? _iso;
  SendPort? _send;
  int _reqId = 0;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _isoPort = ReceivePort();
  StreamSubscription? _isoSub;

  AudioPlayer? _player;
  Completer<bool>? _playDone;
  StreamSubscription? _posSub;
  StreamSubscription? _cmpSub;

  /// Кэш предсинтеза: текст фразы → WAV (prefetch следующего стиха).
  final _cache = <String, _Clip>{};

  /// Идущие синтезы: повторный запрос (speak за prefetch-текстом)
  /// ждёт тот же future, а не отвечает отказом.
  final _synthF = <String, Future<_Clip?>>{};

  final _wordsCtl = StreamController<WordMark>.broadcast();
  List<WSpan> _wspans = const [];
  String _curText = '';
  Duration _curDur = Duration.zero;
  int _curWord = -1;

  int _epoch = 0;
  double _speed = 1.0;
  final int _sid = 0;
  bool _ready = false;

  /// Словарь произношения: базовые имена + pronounce.tsv пакета.
  /// Применяется к тексту синтеза; пословная подсветка идёт по
  /// исходному тексту, поэтому смещения не съезжают.
  PronounceDict _dict = PronounceDict.base;

  @override
  String get id => 'neural';

  // ---------- изолят ----------

  Future<SendPort> _ensureIso() async {
    if (_send != null) return _send!;
    _isoSub ??= _isoPort.listen(_onIsoMsg);
    _iso ??= await Isolate.spawn(_ttsIsolate, _isoPort.sendPort);
    final first = await _pending.putIfAbsent(-1, Completer.new).future;
    _send = first['port'] as SendPort;
    return _send!;
  }

  void _onIsoMsg(Object? raw) {
    final m = raw as Map;
    final id = m['id'] as int? ?? -1;
    _pending.remove(id)?.complete(m.cast<String, Object?>());
  }

  /// Запрос в изолят и ответ по id. Первым изолят шлёт свой SendPort
  /// (id=-1), дальше — ответы на cmd.
  Future<Map<String, Object?>?> _isoCall(Map<String, Object?> req) async {
    final send = await _ensureIso();
    final id = ++_reqId;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    send.send({...req, 'id': id});
    return c.future;
  }

  // ---------- VoiceBackend ----------

  @override
  Future<void> prepare({
    required String language,
    required double rate,
  }) async {
    _speed = rate;
    final r = await _isoCall({
      'cmd': 'init',
      'model': pack.model,
      'tokens': pack.tokens,
      'dataDir': pack.dataDir,
    });
    if (r == null || r['ok'] != true) {
      throw StateError('neural init: ${r?['error'] ?? 'no isolate'}');
    }
    _dict = PronounceDict.merged(pack.dir);
    _accent = pack.language == 'ru' &&
        settings.voiceAccent &&
        await _loadAccentor();
    _ready = true;
  }

  /// Применять ли автоударения (модель RUAccent — только русский,
  /// отключается настройкой; к системному движку не применяется).
  bool _accent = false;

  /// Загрузка акцентора — один раз на процесс (ассеты ~3 МБ, модель
  /// тяжёлая); повторные prepare ждут тот же future.
  static Future<bool>? _accentorReady;

  /// Модель акцентуации из ассетов → мост (один раз на процесс;
  /// без файлов/при ошибке читаем без ударений).
  static Future<bool> _loadAccentor() => _accentorReady ??= () async {
    try {
      final model = await rootBundle.load('assets/voice/ru/accent.onnx');
      final vocab = await rootBundle.loadString('assets/voice/ru/vocab.txt');
      final yo = await rootBundle.load('assets/voice/ru/yo_words.tsv.gz');
      final lexicon = await rootBundle.load('assets/voice/ru/lexicon.tsv.gz');
      await bridgeAccentInit(
        model.buffer.asUint8List(),
        vocab,
        yo.buffer.asUint8List(),
        lexicon.buffer.asUint8List(),
      );
      return true;
    } catch (_) {
      return false;
    }
  }();

  /// Текст для синтеза: словарь произношения (приоритет — слово
  /// с U+0301 нейросеть не трогает), затем автоударения и ё.
  /// Подсветка слов идёт по исходному тексту — смещения не съезжают.
  Future<String> _say(String text) async {
    final t = _dict.apply(text);
    return _accent ? bridgeAccentText(t) : t;
  }

  /// Синтез фразы → WAV. Кэш prefetch: повторный запрос текста
  /// возвращается мгновенно; запрос, идущий в изоляте, дожидается
  /// общего future (speak за prefetch-текстом не отказ).
  Future<_Clip?> _synth(String text) {
    if (!_ready) return Future.value();
    final hit = _cache.remove(text);
    if (hit != null) return Future.value(hit);
    return _synthF.putIfAbsent(text, () => _doSynth(text));
  }

  Future<_Clip?> _doSynth(String text) async {
    try {
      final r = await _isoCall({
        'cmd': 'gen',
        'phrases': [
          for (final p in splitPhrases(text))
            {'t': p.text, 'p': p.pauseMs},
        ],
        'sid': _sid,
        'speed': _speed,
      });
      if (r == null || r['ok'] != true) return null;
      final pcm = (r['pcm'] as TransferableTypedData)
          .materialize()
          .asFloat32List();
      final rate = r['rate'] as int;
      return _Clip(
        wavFromPcm(pcm, rate),
        Duration(microseconds: pcm.length * 1000000 ~/ rate),
      );
    } finally {
      _synthF.remove(text);
    }
  }

  @override
  void prefetch(String text) {
    if (!_ready) return;
    // Фоновой предсинтез; кэш ограничен — главы не накапливаются.
    _say(text).then((say) {
      if (!_ready || _cache.containsKey(say)) return null;
      return _synth(say).then((clip) {
        if (clip == null || _cache.containsKey(say)) return;
        if (_cache.length > 6) _cache.remove(_cache.keys.first);
        _cache[say] = clip;
      });
    });
  }

  @override
  Future<bool> speak(String text) async {
    final ep = ++_epoch;
    _curText = text;
    _wspans = wordSpans(text);
    _curWord = -1;
    final clip = await _synth(await _say(text));
    if (ep != _epoch) return true; // оборвано во время синтеза
    if (clip == null) return false;
    _curDur = clip.duration;
    final p = _player ??= AudioPlayer();
    _cmpSub ??= p.onPlayerComplete.listen((_) => _finish(true));
    _posSub ??= p.onPositionChanged.listen(_onPos);
    try {
      await p.stop();
      // Комплитер — после stop() (оно может сгенерировать onComplete
      // у прошлого аудио), но до play() — иначе быстрый конец фразы
      // потеряет событие завершения.
      _playDone = Completer<bool>();
      await p.play(BytesSource(clip.wav));
    } catch (_) {
      _playDone = null;
      return false;
    }
    return _playDone!.future;
  }

  void _finish(bool ok) {
    final c = _playDone;
    _playDone = null;
    c?.complete(ok);
  }

  /// Позиция звучания → оценочное слово (только при смене слова,
  /// иначе подсветка дёргала бы экран на каждый тик плеера).
  void _onPos(Duration pos) {
    if (_wspans.isEmpty || _curDur.inMilliseconds <= 0) return;
    final w = wordAt(_wspans, _curText, pos.inMilliseconds / _curDur.inMilliseconds);
    if (w == null || w.start == _curWord) return;
    _curWord = w.start;
    if (!_wordsCtl.isClosed) _wordsCtl.add(w);
  }

  @override
  bool get canPause => true;

  @override
  Future<void> pause() => _player?.pause() ?? Future.value();

  @override
  Future<void> resume() => _player?.resume() ?? Future.value();

  @override
  Future<void> stop() async {
    _epoch++;
    _finish(false);
    await _player?.stop();
  }

  @override
  Stream<WordMark>? get words => _wordsCtl.stream;

  @override
  void dispose() {
    _epoch++;
    _ready = false;
    _finish(false);
    _posSub?.cancel();
    _cmpSub?.cancel();
    _player?.dispose();
    _send?.send({'cmd': 'close', 'id': -2});
    _iso?.kill();
    _isoSub?.cancel();
  }
}
