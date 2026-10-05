import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_tts/flutter_tts.dart';

import '../l10n.dart';
import '../tts_media.dart';

/// Сервис чтения главы вслух.
///
/// Состояние плеера и очередь стихов изолированы здесь; экран даёт
/// колбэки для перерисовки, прокрутки к стиху и показа ошибок.
class ReaderTtsService {
  ReaderTtsService({
    required this.isActive,
    required this.onChanged,
    required this.onVerse,
    required this.onError,
    required this.titleOf,
  });

  /// Экран ещё жив (аналог mounted).
  final bool Function() isActive;

  /// Перерисовать UI после изменения состояния.
  final void Function() onChanged;

  /// Прокрутить текст к читаемому стиху.
  final void Function(int verse) onVerse;

  /// Показать пользователю сообщение об ошибке.
  final void Function(String message) onError;

  /// Заголовок медиа-сессии для текущей главы.
  final String Function() titleOf;

  FlutterTts? _tts;
  bool _playing = false;
  bool _paused = false;
  int? _verse;

  /// Очередь чтения: стих -> текст, и текущая позиция в ней.
  List<MapEntry<int, String>> _list = const [];
  int _index = 0;

  /// Поколение запуска TTS — отменяет цикл чтения при стопе/смене главы.
  int _epoch = 0;
  String _language = 'ru-RU';

  bool get playing => _playing;
  bool get paused => _paused;
  int? get verse => _verse;
  List<MapEntry<int, String>> get list => _list;
  int get index => _index;

  Future<void> start({
    required String language,
    required List<MapEntry<int, String>> verses,
  }) async {
    if (verses.isEmpty) return;
    final tts = _tts ??= FlutterTts();
    try {
      // На Android без объявления TTS_SERVICE в queries и без
      // движка синтез молча не работает — сообщаем явно.
      if (!kIsWeb) {
        final engines = await tts.getEngines;
        if (engines is List && engines.isEmpty) {
          throw StateError('no tts engine');
        }
      }
      // Голос для языка может быть не скачан — проверяем явно,
      // иначе speak() завершается мгновенно и глава «пролетает».
      final langOk = await tts.isLanguageAvailable(language);
      if (langOk != true) {
        throw StateError('no voice for $language');
      }
      await tts.setLanguage(language);
      await tts.setSpeechRate(0.45);
      await tts.setVolume(1.0);
      await tts.setPitch(1.0);
      await tts.awaitSpeakCompletion(true);
    } catch (_) {
      if (isActive()) {
        onError(
          tr(
            'Синтез речи недоступен: проверьте TTS-движок и голос языка в настройках Android',
            'Speech synthesis unavailable: check the TTS engine and voice in Android settings',
          ),
        );
      }
      return;
    }
    _language = language;
    _list = verses;
    await readAloud.ensurePermission();
    readAloud.setCallbacks(
      onPause: pause,
      onResume: resume,
      onPrev: () => seek(-1),
      onNext: () => seek(1),
      onStop: stop,
    );
    await speakFrom(0);
  }

  /// Цикл чтения с позиции [start] в очереди. Каждый запуск —
  /// новое поколение: старый цикл гаснет на ближайшей итерации.
  Future<void> speakFrom(int start) async {
    final tts = _tts;
    if (tts == null || _list.isEmpty) return;
    final epoch = ++_epoch;
    // flutter_tts с QUEUE_FLUSH + awaitSpeakCompletion отклоняет
    // новый speak() (возвращает 0), пока играет прежний стих —
    // поэтому сначала останавливаем текущее воспроизведение.
    await tts.stop();
    _playing = true;
    _paused = false;
    onChanged();
    var failed = false;
    var i = start;
    for (; i < _list.length; i++) {
      if (!isActive() || _epoch != epoch) break;
      _index = i;
      final e = _list[i];
      _verse = e.key;
      onChanged();
      _pushMediaState(e.key, i);
      onVerse(e.key);
      // speak() возвращает 0, если движок не принял фразу —
      // ловим, иначе глава молча «пролетает» до конца.
      var r = await tts.speak(e.value);
      if (r == 0 && _epoch == epoch) {
        // Может ещё идти остановка прерванного стиха —
        // даём движку секундный шанс перед объявлением отказа.
        await Future.delayed(const Duration(milliseconds: 250));
        if (_epoch == epoch) r = await tts.speak(e.value);
      }
      if (r == 0) {
        failed = true;
        break;
      }
    }
    // Проверка поколения: отменённый stop()/перемоткой speak()
    // тоже возвращает 0 — это не отказ движка, ошибку не показываем.
    if (failed && isActive() && _epoch == epoch) {
      onError(
        tr(
          'Движок синтеза не принял текст: проверьте голос $_language в настройках Android',
          'Speech engine rejected the text: check the $_language voice in Android settings',
        ),
      );
    }
    if (isActive() && _epoch == epoch) stop();
  }

  /// Синхронизация медиа-сессии (уведомление/шторка) с позицией
  /// чтения: прогресс идёт по стихам главы.
  void _pushMediaState(int? verse, int index) {
    readAloud.update(
      title: titleOf(),
      subtitle: verse == null ? '' : tr('стих $verse', 'verse $verse'),
      index: index,
      total: _list.length,
      playing: !_paused,
    );
  }

  void pause() {
    if (!_playing || _paused) return;
    _epoch++; // прерывает цикл чтения
    _tts?.stop();
    _paused = true;
    onChanged();
    _pushMediaState(_verse, _index);
  }

  void resume() {
    if (!_playing || !_paused) return;
    speakFrom(_index); // текущий стих заново с начала
  }

  /// Переход ползунком плеера на стих с индексом [i]: на паузе
  /// только сдвигает позицию, при игре — сразу озвучивает его.
  void slide(int i) {
    if (!_playing || _list.isEmpty) return;
    i = i.clamp(0, _list.length - 1);
    if (_paused) {
      _index = i;
      _verse = _list[i].key;
      onChanged();
      _pushMediaState(_verse, i);
      onVerse(_verse!);
    } else {
      speakFrom(i);
    }
  }

  /// Перемотка на [dir] стихов. На паузе — просто сдвигает
  /// позицию, при игре — сразу озвучивает новый стих.
  void seek(int dir) {
    if (!_playing) return;
    final i = _index + dir;
    if (i < 0 || i >= _list.length) return;
    if (_paused) {
      _index = i;
      _verse = _list[i].key;
      onChanged();
      _pushMediaState(_verse, i);
      onVerse(_verse!);
    } else {
      speakFrom(i);
    }
  }

  void stop() {
    _epoch++;
    _tts?.stop();
    readAloud.clear();
    if (isActive()) {
      _playing = false;
      _paused = false;
      _verse = null;
      onChanged();
    }
  }

  void dispose() {
    _epoch++;
    _tts?.stop();
    readAloud.clear();
  }
}
