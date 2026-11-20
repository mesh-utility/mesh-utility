import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mesh_utility/src/config/app_config.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/worker_api.dart';

/// Owns sync UI state, the periodic-sync timer, and the internet-time anchor.
///
/// AppState orchestrates the actual data work; SyncService is notified via
/// [beginSync], [completeSync], and [failSync].
class SyncService extends ChangeNotifier {
  SyncService({Duration Function()? elapsed}) : _elapsedOverride = elapsed;

  final _log = AppDebugLogService.instance;
  final Duration Function()? _elapsedOverride;

  bool syncing = false;
  String? error;
  DateTime? lastSyncAt;
  int lastSyncScanCount = 0;

  // Internet time anchor (monotonic clock + server UTC offset).
  final Stopwatch _monotonicStopwatch = Stopwatch()..start();
  Duration get _monoElapsed =>
      _elapsedOverride?.call() ?? _monotonicStopwatch.elapsed;
  DateTime? _internetTimeAnchorUtc;
  Duration? _internetTimeAnchorElapsed;
  DateTime? _lastPeriodicSyncInternetUtc;
  bool _internetTimeRefreshInFlight = false;

  Timer? _periodicSyncTimer;
  int? _periodicIntervalMinutes;
  bool _periodicTickInFlight = false;
  Duration? _lastSyncElapsed;

  /// How often the periodic timer checks whether a sync is due. The check
  /// itself is cheap; the configured interval decides when a sync runs.
  @visibleForTesting
  static Duration periodicCheckEvery = const Duration(minutes: 1);

  /// Called when the periodic sync timer decides it is time to sync.
  /// Wire this to [AppState.syncFromWorker].
  Future<void> Function()? onPeriodicSyncDue;

  /// Return false to suppress a periodic sync tick (e.g. while loading).
  bool Function()? isReadyToSync;

  // ── State transitions ────────────────────────────────────────────────────

  void beginSync() {
    syncing = true;
    error = null;
    notifyListeners();
  }

  void completeSync(int count) {
    syncing = false;
    lastSyncAt = DateTime.now();
    // Any finished sync (manual, on-connect, startup or periodic) restarts
    // the periodic interval. The viewport sync path never recorded this, so
    // the 1-minute check saw "never synced" and synced every minute.
    _lastSyncElapsed = _monoElapsed;
    final internetNow = estimatedInternetNowUtc();
    if (internetNow != null) _lastPeriodicSyncInternetUtc = internetNow;
    lastSyncScanCount = count;
    error = null;
    notifyListeners();
  }

  void failSync(String message) {
    syncing = false;
    error = message;
    notifyListeners();
  }

  /// Stops the sync indicator without recording a failure or a success.
  void abandonSync() {
    syncing = false;
    notifyListeners();
  }

  // ── Internet time anchor ─────────────────────────────────────────────────

  void captureInternetTimeAnchor(DateTime? serverUtc) {
    if (serverUtc == null) return;
    _internetTimeAnchorUtc = serverUtc.toUtc();
    _internetTimeAnchorElapsed = _monoElapsed;
    _log.debug(
      'sync',
      'Internet time anchor updated: ${_internetTimeAnchorUtc!.toIso8601String()}',
    );
  }

  DateTime? estimatedInternetNowUtc() {
    final anchorUtc = _internetTimeAnchorUtc;
    final anchorElapsed = _internetTimeAnchorElapsed;
    if (anchorUtc == null || anchorElapsed == null) return null;
    final delta = _monoElapsed - anchorElapsed;
    return anchorUtc.add(delta);
  }

  void recordPeriodicSyncTime(DateTime utc) {
    _lastPeriodicSyncInternetUtc = utc;
  }

  Future<void> refreshInternetTimeAnchor() async {
    if (_internetTimeRefreshInFlight) return;
    _internetTimeRefreshInFlight = true;
    try {
      final api = WorkerApi(
        AppConfig.deployedWorkerUrl,
        fallbackBaseUrl: AppConfig.fallbackWorkerUrl,
        staticDataBaseUrl: AppConfig.staticDataUrl,
      );
      final serverNow = await api.fetchServerUtcNow();
      captureInternetTimeAnchor(serverNow);
    } catch (e) {
      _log.debug('sync', 'Internet time refresh failed: $e');
    } finally {
      _internetTimeRefreshInFlight = false;
    }
  }

  // ── Computed getters ─────────────────────────────────────────────────────

  bool get waitingForInternetTimeAnchor =>
      _periodicSyncTimer != null && estimatedInternetNowUtc() == null;

  DateTime? nextPeriodicSyncDueAtUtc(int intervalMinutes) {
    if (_periodicSyncTimer == null) return null;
    final internetNow = estimatedInternetNowUtc();
    if (internetNow == null) return null;
    final last = _lastPeriodicSyncInternetUtc;
    if (last == null) return internetNow;
    return last.add(Duration(minutes: intervalMinutes));
  }

  // ── Periodic timer ────────────────────────────────────────────────────────

  void configure({required int intervalMinutes, required bool forceOffline}) {
    if (!forceOffline &&
        _periodicSyncTimer != null &&
        _periodicIntervalMinutes == intervalMinutes) {
      // Same settings: keep the one running timer (no duplicate, no reset).
      return;
    }
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
    _periodicIntervalMinutes = null;
    if (forceOffline) {
      _log.info('sync', 'Periodic sync disabled (offline mode enabled)');
      return;
    }
    _periodicIntervalMinutes = intervalMinutes;
    _periodicSyncTimer = Timer.periodic(periodicCheckEvery, (_) {
      unawaited(maybeRunPeriodicSync(intervalMinutes));
    });
    _log.info('sync', 'Periodic sync scheduled interval=${intervalMinutes}m');
  }

  void stopTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
    _periodicIntervalMinutes = null;
  }

  @visibleForTesting
  bool get hasPeriodicTimer => _periodicSyncTimer != null;

  /// One periodic check. Public for tests; the timer calls it.
  @visibleForTesting
  Future<void> maybeRunPeriodicSync(int intervalMinutes) async {
    if (_periodicTickInFlight) return;
    _periodicTickInFlight = true;
    try {
      await _maybeRun(intervalMinutes);
    } finally {
      _periodicTickInFlight = false;
    }
  }

  Future<void> _maybeRun(int intervalMinutes) async {
    if (syncing) return;
    if (isReadyToSync != null && !isReadyToSync!()) return;

    final interval = Duration(minutes: intervalMinutes);
    // Monotonic guard: works even before the internet-time anchor exists
    // (the viewport sync does not capture one).
    final lastElapsed = _lastSyncElapsed;
    if (lastElapsed != null &&
        _monoElapsed - lastElapsed < interval) {
      return;
    }
    var internetNow = estimatedInternetNowUtc();
    if (internetNow == null) {
      await refreshInternetTimeAnchor();
      internetNow = estimatedInternetNowUtc();
    }
    if (internetNow == null) {
      _log.warn('sync', 'Periodic sync waiting for internet time anchor');
      return;
    }

    final last = _lastPeriodicSyncInternetUtc;
    if (last != null && internetNow.difference(last) < interval) return;

    _log.info(
      'sync',
      'Periodic sync trigger (internet time) interval=${intervalMinutes}m',
    );
    // Start the next interval now so a failed or skipped sync waits a full
    // interval instead of retrying on every 1-minute check.
    _lastPeriodicSyncInternetUtc = internetNow;
    _lastSyncElapsed = _monoElapsed;
    await onPeriodicSyncDue?.call();
  }

  @override
  void dispose() {
    stopTimer();
    super.dispose();
  }
}
