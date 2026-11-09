import 'dart:ui';

/// Whether the Android location stream should run as a foreground service
/// while the user wants the BLE scan loop.
///
/// The service holds a persistent notification and a partial wake lock so the
/// one-second loop timer, and the reconnect timer, are not deferred while the
/// phone is asleep.
///
/// Hold while the loop is running on a live radio link, or while [loopWanted]
/// is still true during a reconnect. The caller sets [loopWanted] false when
/// the user pauses or stops the loop, disconnects the radio, or reconnect is
/// abandoned.
///
/// Background location is not required when [appInForeground] is true. Android
/// lets a visible app start a location foreground service with while-in-use
/// location. Callers pass the latch captured when the loop started, not the
/// live lifecycle, so a screen-off reconnect does not look like a background
/// start. Starting that service from the background without background
/// location throws on Android 14+, so that case stays off.
bool shouldHoldAndroidScanForeground({
  required bool isAndroidNative,
  required bool scanLoopRunning,
  required bool bleConnected,
  required bool backgroundLocationGranted,
  required bool appInForeground,
  bool loopWanted = false,
}) {
  if (!isAndroidNative) return false;
  final keepAlive = loopWanted || (scanLoopRunning && bleConnected);
  if (!keepAlive) return false;
  if (backgroundLocationGranted) return true;
  return appInForeground;
}

/// Delay before scan-loop reconnect attempt [attempt].
///
/// Attempt 0 waits 2s, then 5s, 10s, 20s, 30s, and every later attempt waits
/// 60s. A failed attempt must not clear the caller's "loop wanted" flag.
Duration scanReconnectBackoffDelay(int attempt) {
  const seconds = <int>[2, 5, 10, 20, 30, 60];
  if (attempt <= 0) return const Duration(seconds: 2);
  if (attempt >= seconds.length - 1) return const Duration(seconds: 60);
  return Duration(seconds: seconds[attempt]);
}

/// True when the activity is visible enough to start a location foreground
/// service without background location.
///
/// [AppLifecycleState.inactive] is treated as background. Screen-off passes
/// through inactive, and starting the service in that window can throw.
/// A null state means the binding has not reported one yet (startup); the
/// loop start that happens then is a foreground user action.
bool androidUiIsInForeground(AppLifecycleState? state) {
  return state == null || state == AppLifecycleState.resumed;
}
