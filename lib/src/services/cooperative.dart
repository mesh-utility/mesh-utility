/// Yields to the event loop when [watch] passed [budget], so the browser can
/// paint and handle input.
class FrameBudget {
  FrameBudget({this.budget = const Duration(milliseconds: 8)});

  /// Longest slice of work before the next browser turn.
  final Duration budget;

  /// Elapsed time since the last yield.
  final Stopwatch watch = Stopwatch()..start();

  /// Returned by [maybeYield] when the caller should keep working.
  ///
  /// Awaiting this future schedules a microtask, which still runs before the
  /// browser can paint. Hot loops must await [maybeYield] only when the
  /// result is not [idle].
  static final Future<void> idle = Future<void>.value();

  int _untilCheck = 64;

  /// Completed [idle] unless [budget] has elapsed.
  ///
  /// The clock is read every 64 calls.
  Future<void> maybeYield() {
    if (--_untilCheck > 0) return idle;
    _untilCheck = 64;
    if (watch.elapsed < budget) return idle;
    return _yield();
  }

  Future<void> _yield() async {
    await Future<void>.delayed(Duration.zero);
    watch
      ..reset()
      ..start();
  }
}
