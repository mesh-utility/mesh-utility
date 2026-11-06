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
  final _log = AppDebugLogService.instance;

  bool syncing = false;
  String? error;
  DateTime? lastSyncAt;
  int lastSyncScanCount = 0;

  // Internet time anchor (monotonic clock + server UTC offset).
  final Stopwatch _monotonicClock = Stopwatch()..start();
  DateTime? _internetTimeAnchorUtc;
  Duration? _internetTimeAnchorElapsed;
  DateTime? _lastPeriodicSyncInternetUtc;
  bool _internetTimeRefreshInFlight = false;

  Timer? _periodicSyncTimer;

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
    lastSyncScanCount = count;
    error = null;
    notifyListeners();
  }

  void failSync(String message) {
    syncing = false;
    error = message;
    notifyListeners();
  }

  // ── Internet time anchor ─────────────────────────────────────────────────

  void captureInternetTimeAnchor(DateTime? serverUtc) {
    if (serverUtc == null) return;
    _internetTimeAnchorUtc = serverUtc.toUtc();
    _internetTimeAnchorElapsed = _monotonicClock.elapsed;
    _log.debug(
      'sync',
      'Internet time anchor updated: ${_internetTimeAnchorUtc!.toIso8601String()}',
    );
  }

  DateTime? estimatedInternetNowUtc() {
    final anchorUtc = _internetTimeAnchorUtc;
    final anchorElapsed = _internetTimeAnchorElapsed;
    if (anchorUtc == null || anchorElapsed == null) return null;
    final delta = _monotonicClock.elapsed - anchorElapsed;
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
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
    if (forceOffline) {
      _log.info('sync', 'Periodic sync disabled (offline mode enabled)');
      return;
    }
    _periodicSyncTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_maybeRun(intervalMinutes));
    });
    _log.info('sync', 'Periodic sync scheduled interval=${intervalMinutes}m');
  }

  void stopTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }

  Future<void> _maybeRun(int intervalMinutes) async {
    if (syncing) return;
    if (isReadyToSync != null && !isReadyToSync!()) return;

    final interval = Duration(minutes: intervalMinutes);
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
    await onPeriodicSyncDue?.call();
  }

  @override
  void dispose() {
    stopTimer();
    super.dispose();
  }
}
