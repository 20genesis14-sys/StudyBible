import 'dart:async';

import '../l10n.dart';
import '../state.dart';
import '../tts_media.dart';
import '../voice/voice_backend.dart';
import '../voice/voice_pick.dart';

/// Сервис чтения главы вслух.
///
/// Состояние плеера, очередь стихов и медиа-сессия изолированы здесь;
/// бэкенд (`system`/`neural`, ADR 0017) только «говорит фразу».
/// Экран даёт колбэки для перерисовки, прокрутки к стиху и показа
/// ошибок.
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

  VoiceBackend? _backend;
  StreamSubscription<WordMark>? _wordsSub;
  bool _playing = false;
  bool _paused = false;
  bool _midPaused = false;
  int? _verse;

  /// Текущее слово читаемого стиха (пословная подсветка, настройка
  /// «Подсветка слов»; null — бэкенд не сообщает позицию).
  WordMark? _word;

  /// Очередь чтения: стих -> текст, и текущая позиция в ней.
  List<MapEntry<int, String>> _list = const [];
  int _index = 0;

  /// Поколение запуска TTS — отменяет цикл чтения при стопе/смене главы.
  int _epoch = 0;

  bool get playing => _playing;
  bool get paused => _paused;
  int? get verse => _verse;
  WordMark? get word => _word;
  List<MapEntry<int, String>> get list => _list;
  int get index => _index;

  /// id активного бэкенда ('system'/'neural') — для значка в плеере.
  String? get backendId => _backend?.id;

  Future<void> start({
    required String language,
    required List<MapEntry<int, String>> verses,
  }) async {
    if (verses.isEmpty) return;
    final pick = await pickVoiceBackend(language);
    if (pick.backend == null) {
      if (isActive() && pick.error != null) onError(pick.error!);
      return;
    }
    _backend?.dispose();
    _backend = pick.backend;
    _wordsSub?.cancel();
    _wordsSub = _backend!.words?.listen((w) {
      if (!settings.voiceWords) return;
      if (_word?.start == w.start && _word?.end == w.end) return;
      _word = w;
      if (isActive()) onChanged();
    });
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
    final backend = _backend;
    if (backend == null || _list.isEmpty) return;
    final epoch = ++_epoch;
    await backend.stop();
    _playing = true;
    _paused = false;
    _midPaused = false;
    onChanged();
    var failed = false;
    var i = start;
    for (; i < _list.length; i++) {
      if (!isActive() || _epoch != epoch) break;
      _index = i;
      final e = _list[i];
      _verse = e.key;
      _word = null;
      onChanged();
      _pushMediaState(e.key, i);
      onVerse(e.key);
      // Предсинтез следующего стиха пока звучит текущий —
      // переходы без паузы движка (нейробэкенд; у system — no-op).
      final fut = backend.speak(e.value);
      if (i + 1 < _list.length) backend.prefetch(_list[i + 1].value);
      var ok = await fut;
      if (!ok && _epoch == epoch) {
        // Может ещё идти остановка прерванного стиха —
        // даём движку секундный шанс перед объявлением отказа.
        await Future.delayed(const Duration(milliseconds: 250));
        if (_epoch == epoch) ok = await backend.speak(e.value);
      }
      if (!ok) {
        failed = true;
        break;
      }
    }
    // Проверка поколения: отменённый stop()/перемоткой speak()
    // тоже возвращает false — это не отказ движка, ошибку не показываем.
    if (failed && isActive() && _epoch == epoch) {
      onError(
        tr(
          'Движок синтеза не принял текст — проверьте настройку голоса',
          'Speech engine rejected the text — check the voice setting',
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
    if (_backend?.canPause ?? false) {
      // Нейробэкенд ставит аудио на паузу посреди фразы — resume
      // продолжает с места, стих не перечитывается.
      _midPaused = true;
      _backend!.pause();
    } else {
      _epoch++; // прерывает цикл чтения
      _backend?.stop();
    }
    _paused = true;
    onChanged();
    _pushMediaState(_verse, _index);
  }

  void resume() {
    if (!_playing || !_paused) return;
    if (_midPaused) {
      _paused = false;
      _midPaused = false;
      _backend?.resume();
      onChanged();
      _pushMediaState(_verse, _index);
    } else {
      speakFrom(_index); // текущий стих заново с начала
    }
  }

  /// Переход ползунком плеера на стих с индексом [i]: на паузе
  /// только сдвигает позицию, при игре — сразу озвучивает его.
  void slide(int i) {
    if (!_playing || _list.isEmpty) return;
    i = i.clamp(0, _list.length - 1);
    if (_paused) {
      _index = i;
      _verse = _list[i].key;
      _dropMidPause();
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
      _dropMidPause();
      onChanged();
      _pushMediaState(_verse, i);
      onVerse(_verse!);
    } else {
      speakFrom(i);
    }
  }

  /// Перемотка на паузе у нейробэкенда обрывает приостановленное
  /// аудио прошлого стиха — иначе resume продолжил бы чужой текст
  /// с уже сдвинутой позицией.
  void _dropMidPause() {
    if (!_midPaused) return;
    _midPaused = false;
    _backend?.stop();
  }

  void stop() {
    _epoch++;
    _wordsSub?.cancel();
    _wordsSub = null;
    _backend?.stop();
    readAloud.clear();
    if (isActive()) {
      _playing = false;
      _paused = false;
      _midPaused = false;
      _verse = null;
      _word = null;
      onChanged();
    }
  }

  void dispose() {
    _epoch++;
    _wordsSub?.cancel();
    _backend?.dispose();
    _backend = null;
    readAloud.clear();
  }
}
