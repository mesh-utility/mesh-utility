import 'dart:async';

/// Delivers the latest [T] after [delay] of quiet.
///
/// Each [schedule] restarts the timer. A value equal to the last one delivered
/// is skipped. [cancel] drops a pending delivery.
class SettleDebouncer<T> {
  SettleDebouncer({required this.delay, required this.onSettled, this.isSame});

  final Duration delay;
  final void Function(T value) onSettled;
  final bool Function(T previous, T next)? isSame;

  Timer? _timer;
  _Held<T>? _latest;
  _Held<T>? _sent;

  void schedule(T value) {
    _latest = _Held<T>(value);
    _timer?.cancel();
    _timer = Timer(delay, _fire);
  }

  void _fire() {
    _timer = null;
    final latest = _latest;
    if (latest == null) return;
    final sent = _sent;
    if (sent != null && _valuesMatch(sent.value, latest.value)) return;
    _sent = latest;
    onSettled(latest.value);
  }

  bool _valuesMatch(T previous, T next) {
    final isSame = this.isSame;
    if (isSame != null) return isSame(previous, next);
    return previous == next;
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

class _Held<T> {
  const _Held(this.value);
  final T value;
}
