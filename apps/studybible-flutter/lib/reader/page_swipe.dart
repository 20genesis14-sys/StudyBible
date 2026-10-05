import 'package:flutter/material.dart';

/// Постраничный свайп по главам.
///
/// Использует Listener, а не GestureDetector: распознаватель жестов
/// конфликтует с SelectionArea и мешает выделять текст.
class ReaderPageSwipe<T> extends StatefulWidget {
  const ReaderPageSwipe({
    super.key,
    required this.child,
    required this.targetFor,
    required this.prepareTarget,
    required this.peekBuilder,
    required this.canStart,
    required this.onTap,
    required this.onCommit,
  });

  final Widget child;

  /// Цель перехода без побочных эффектов; null — край навигации.
  final T? Function(int dir) targetFor;

  /// Подготовить целевую страницу заранее (например, загрузить главу).
  final void Function(T target) prepareTarget;

  /// Страница-подгляд рядом с текущей.
  final Widget Function(T target) peekBuilder;

  /// Разрешить жест (выделенный текст запрещает листание).
  final bool Function() canStart;

  /// Короткий тап по тексту.
  final VoidCallback onTap;

  /// Завершить переход в направлении [dir].
  final void Function(int dir) onCommit;

  @override
  State<ReaderPageSwipe<T>> createState() => _ReaderPageSwipeState<T>();
}

class _ReaderPageSwipeState<T> extends State<ReaderPageSwipe<T>>
    with SingleTickerProviderStateMixin {
  /// Начало свайпа для навигации по главам.
  Offset? _swipeDown;
  Duration _swipeDownAt = Duration.zero;
  int _swipePointer = -1;

  /// Палец ведёт переход; рядом с текущей видна входящая страница.
  bool _dragging = false;
  int _dragPointer = -1;
  double _anchor = 0;
  double _dx = 0;
  int _dir = 0;
  T? _target;
  final _dxTrack = <MapEntry<Duration, double>>[];
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 190),
    );
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  /// Начало постраничного листания: цель — как у onCommit, страница
  /// готовится заранее, чтобы входящая была уже с содержимым.
  void _startDrag(int dir, int pointer, double rawDx) {
    if (!widget.canStart()) return;
    final target = widget.targetFor(dir);
    if (target == null) return; // край навигации
    _dragging = true;
    _dragPointer = pointer;
    _anchor = rawDx;
    _dir = dir;
    _target = target;
    _dxTrack.clear();
    widget.prepareTarget(target);
    setState(() {});
  }

  /// Палец отпущен: при достаточном сдвиге или броске доводим переход
  /// до конца и совершаем onCommit, иначе страница возвращается назад.
  void _endDrag() {
    _swipeDown = null;
    final w = context.size?.width ?? 400;
    var vel = 0.0;
    if (_dxTrack.length >= 2) {
      final a = _dxTrack.first;
      final b = _dxTrack.last;
      final dt = (b.key - a.key).inMilliseconds;
      if (dt > 0) vel = (b.value - a.value) / dt;
    }
    final dir = _dir;
    // Листаем дальше, если перетянули четверть экрана или отпустили
    // с броском в сторону драга (~400 px/s).
    final commit =
        _dx.abs() > w * 0.25 || (vel.abs() > 0.4 && vel.sign == _dx.sign);
    final anim = Tween<double>(
      begin: _dx,
      end: commit ? -dir * w : 0.0,
    ).animate(CurvedAnimation(parent: _ctl, curve: Curves.easeOutCubic));
    void tick() => setState(() => _dx = anim.value);
    anim.addListener(tick);
    _ctl.forward(from: 0).then((_) {
      anim.removeListener(tick);
      if (!mounted) return;
      _dragging = false;
      _dx = 0;
      _target = null;
      // onCommit сам перерисует: входящая страница стала текущей.
      if (commit) widget.onCommit(dir);
    });
  }

  /// Область чтения: во время листания текущая страница едет за
  /// пальцем, сбоку подъезжает входящая; в покое — просто child.
  Widget _pageStack() {
    final target = _target;
    if ((!_dragging && _dx == 0) || target == null) return widget.child;
    return LayoutBuilder(
      builder: (_, c) {
        final w = c.maxWidth;
        return Stack(
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(_dx + _dir * w, 0),
                child: widget.peekBuilder(target),
              ),
            ),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(_dx, 0),
                child: widget.child,
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _swipeDown = e.position;
        _swipeDownAt = e.timeStamp;
        _swipePointer = e.pointer;
      },
      onPointerMove: (e) {
        if (e.pointer != _swipePointer) return;
        final s = _swipeDown;
        if (s == null) return;
        final raw = e.position.dx - s.dx;
        if (_dragging) {
          if (e.pointer != _dragPointer) return;
          _dx = raw - _anchor;
          _dxTrack.add(MapEntry(e.timeStamp, _dx));
          if (_dxTrack.length > 8) _dxTrack.removeAt(0);
          setState(() {});
          return;
        }
        final dy = e.position.dy - s.dy;
        // Порог старта листания: явно горизонтальный жест.
        if (raw.abs() > 26 && raw.abs() > dy.abs() * 1.5) {
          _startDrag(raw < 0 ? 1 : -1, e.pointer, raw);
        }
      },
      onPointerCancel: (_) {
        _swipeDown = null;
        if (_dragging) _endDrag();
      },
      onPointerUp: (e) {
        if (_dragging) {
          _endDrag();
          return;
        }
        final s = _swipeDown;
        _swipeDown = null;
        if (s == null) return;
        final tapDx = (e.position.dx - s.dx).abs();
        final tapDy = (e.position.dy - s.dy).abs();
        if (tapDx < 10 && tapDy < 10) {
          widget.onTap();
          return;
        }
        // Если жест закончился выделением текста — это не свайп.
        if (!widget.canStart()) return;
        final dx = e.position.dx - s.dx;
        final dy = e.position.dy - s.dy;
        final dt = e.timeStamp - _swipeDownAt;
        if (dt < const Duration(milliseconds: 900) &&
            dx.abs() > 60 &&
            dx.abs() > dy.abs() * 1.5) {
          widget.onCommit(dx < 0 ? 1 : -1);
        }
      },
      child: _pageStack(),
    );
  }
}
