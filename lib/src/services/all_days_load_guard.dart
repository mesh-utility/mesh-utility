import 'dart:async';
import 'dart:math';

import 'package:mesh_utility/src/services/guard_peer_probe.dart';
import 'package:mesh_utility/src/services/guard_peer_probe_stub.dart'
    if (dart.library.io) 'package:mesh_utility/src/services/guard_peer_probe_stub.dart'
    if (dart.library.js_interop) 'package:mesh_utility/src/services/guard_peer_probe_web.dart'
    as guard_probe;
import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/reax_database.dart';
import 'package:mesh_utility/src/services/reax_database_backend_base.dart';
import 'package:mesh_utility/src/services/settings_store.dart';

/// Startup marker for an all-days history load.
///
/// The marker is written before the load starts and removed only after that
/// load finishes. Each app start has its own owner id. A heartbeat keeps the
/// marker fresh, and another tab asks whether that owner is still alive
/// before it changes the saved window. A kill or a freeze that leaves the
/// marker stale falls back to the last 7 days so Settings can be reached. A
/// first upgrade has no marker yet: the all-days choice is kept, and the
/// cached history is processed off the UI isolate.
class AllDaysLoadGuard {
  AllDaysLoadGuard({
    AppKvDatabase? database,
    GuardPeerProbe? probe,
    String? ownerId,
    int Function()? nowMs,
  }) : _database = database,
       _probe = probe ?? guard_probe.createGuardPeerProbe(),
       _ownerId = ownerId ?? _newOwnerId(),
       _nowMs = nowMs ?? _systemNowMs {
    _probe.serve(_ownerId);
  }

  static const storageKey = 'settings:allDaysLoadGuard';
  static const last7Days = 7;
  static const heartbeatInterval = Duration(seconds: 5);
  static const staleBeat = Duration(seconds: 20);
  static const peerTimeout = Duration(milliseconds: 400);

  final AppKvDatabase? _database;
  final GuardPeerProbe _probe;
  final String _ownerId;
  final int Function() _nowMs;

  /// Serializes marker writes so a heartbeat cannot resurrect a cleared guard.
  Future<void> _tail = Future<void>.value();
  Timer? _heartbeat;
  bool _beating = false;
  bool _disposed = false;

  String get ownerId => _ownerId;

  Future<AppKvDatabase> _db() async {
    final database = _database;
    if (database != null) return database;
    return ReaxDatabase.instance();
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    // A failed write must not stall the next arm, clear, or heartbeat.
    _tail = run.then((_) {}, onError: (_, _) {});
    return run;
  }

  Future<bool> isArmed() async {
    final mark = _parse(await (await _db()).get(storageKey));
    return mark.armed;
  }

  /// Persist the in-progress marker. Callers must await this before any
  /// all-days cache parse or network fetch.
  Future<void> arm() {
    return _enqueue(() async {
      if (_disposed) return;
      final now = _nowMs();
      await _putOwned(armedAt: now, beat: now);
      if (_disposed) return;
      _startHeartbeat();
    });
  }

  /// Compare-and-clear. A marker owned by another tab is left in place.
  /// Legacy `true` (no owner) is cleared. The heartbeat always stops.
  Future<void> clear() {
    _stopHeartbeat();
    return _enqueue(() async {
      final mark = _parse(await (await _db()).get(storageKey));
      if (!mark.armed) return;
      if (mark.legacy || mark.owner == _ownerId) {
        await (await _db()).put(storageKey, false);
      }
    });
  }

  /// Rewrites [beat] while the stored owner is this instance.
  ///
  /// The heartbeat timer calls this. Tests can call it after moving [nowMs].
  Future<void> beatOnce() {
    return _enqueue(() async {
      if (!_beating || _disposed) return;
      final mark = _parse(await (await _db()).get(storageKey));
      if (!_beating || _disposed) return;
      if (!mark.armed || mark.owner != _ownerId) {
        _stopHeartbeat();
        return;
      }
      final now = _nowMs();
      await _putOwned(armedAt: mark.armedAt ?? now, beat: now);
    });
  }

  /// When a previous all-days load did not finish, move only the all-days
  /// windows to last 7 and persist that before clearing the guard.
  ///
  /// A marker owned by a live tab, or by a tab whose beat is still fresh, is
  /// left alone so a second tab does not truncate All days.
  Future<AllDaysStartupResolution> resolveInterruptedStartup({
    required AppSettings settings,
    required Future<void> Function(AppSettings settings) saveSettings,
  }) {
    return _enqueue(() async {
      final mark = _parse(await (await _db()).get(storageKey));
      if (!mark.armed) {
        return _unchanged(settings);
      }
      if (mark.legacy || mark.owner == _ownerId) {
        return _fallBack(settings, saveSettings);
      }
      final alive = await _peerAlive(mark.owner!);
      if (alive) {
        return _unchanged(settings);
      }
      if (!_beatIsStale(mark)) {
        return _unchanged(settings);
      }
      return _fallBack(settings, saveSettings);
    });
  }

  /// Arms before [load] when [settings] requests all days, and clears only
  /// if [load] returns. [AllDaysLoadIncomplete] leaves the guard armed and
  /// is swallowed. Any other error leaves the guard armed and is rethrown.
  Future<void> guardedAllDaysLoad({
    required AppSettings settings,
    required Future<void> Function() load,
  }) async {
    final shouldGuard = requestsAllDays(
      historyDays: settings.historyDays,
      deadzoneDays: settings.deadzoneDays,
    );
    if (shouldGuard) {
      await arm();
    }
    try {
      await load();
      if (shouldGuard) {
        await clear();
      }
    } on AllDaysLoadIncomplete {
      // The attempt did not finish. The armed guard falls back on next start.
    }
  }

  /// Stops the heartbeat and the peer listener. The stored marker is kept so
  /// a kill or a freeze can still fall back on the next start.
  void dispose() {
    _disposed = true;
    _stopHeartbeat();
    _probe.close();
  }

  Future<AllDaysStartupResolution> _fallBack(
    AppSettings settings,
    Future<void> Function(AppSettings settings) saveSettings,
  ) async {
    final next = fallbackInterruptedAllDays(settings);
    final changed =
        next.historyDays != settings.historyDays ||
        next.deadzoneDays != settings.deadzoneDays;
    if (changed) {
      await saveSettings(next);
    }
    _stopHeartbeat();
    await (await _db()).put(storageKey, false);
    return AllDaysStartupResolution(
      settings: changed ? next : settings,
      fellBackToLast7: changed,
    );
  }

  AllDaysStartupResolution _unchanged(AppSettings settings) {
    return AllDaysStartupResolution(settings: settings, fellBackToLast7: false);
  }

  Future<bool> _peerAlive(String owner) async {
    try {
      return await _probe.isAlive(owner, peerTimeout);
    } catch (_) {
      return false;
    }
  }

  bool _beatIsStale(_GuardMark mark) {
    final stamp = mark.beat ?? mark.armedAt;
    if (stamp == null) return true;
    return _nowMs() - stamp > staleBeat.inMilliseconds;
  }

  Future<void> _putOwned({required int armedAt, required int beat}) async {
    await (await _db()).put(storageKey, <String, Object?>{
      'owner': _ownerId,
      'armedAt': armedAt,
      'beat': beat,
    });
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _beating = true;
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      unawaited(beatOnce());
    });
  }

  void _stopHeartbeat() {
    _beating = false;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  static int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;
}

class AllDaysStartupResolution {
  const AllDaysStartupResolution({
    required this.settings,
    required this.fellBackToLast7,
  });

  final AppSettings settings;
  final bool fellBackToLast7;
}

/// Signals that an all-days load stopped short of success.
class AllDaysLoadIncomplete implements Exception {
  const AllDaysLoadIncomplete();
}

/// All-days windows become last 7. Finite windows are left as the user set them.
AppSettings fallbackInterruptedAllDays(AppSettings settings) {
  final historyDays = isAllDaysWindow(settings.historyDays)
      ? AllDaysLoadGuard.last7Days
      : settings.historyDays;
  final deadzoneDays = isAllDaysWindow(settings.deadzoneDays)
      ? AllDaysLoadGuard.last7Days
      : settings.deadzoneDays;
  if (historyDays == settings.historyDays &&
      deadzoneDays == settings.deadzoneDays) {
    return settings;
  }
  return settings.copyWith(
    historyDays: historyDays,
    deadzoneDays: deadzoneDays,
  );
}

String _newOwnerId() {
  final random = Random();
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final noise = random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0');
  final extra = random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0');
  return '$time-$noise$extra';
}

class _GuardMark {
  const _GuardMark.idle()
    : armed = false,
      legacy = false,
      owner = null,
      armedAt = null,
      beat = null;

  const _GuardMark.legacy()
    : armed = true,
      legacy = true,
      owner = null,
      armedAt = null,
      beat = null;

  const _GuardMark.owned({
    required this.owner,
    required this.armedAt,
    required this.beat,
  }) : armed = true,
       legacy = false;

  final bool armed;
  final bool legacy;
  final String? owner;
  final int? armedAt;
  final int? beat;
}

_GuardMark _parse(Object? raw) {
  if (raw == true) return const _GuardMark.legacy();
  if (raw is Map) {
    final owner = raw['owner'];
    if (owner is String && owner.isNotEmpty) {
      return _GuardMark.owned(
        owner: owner,
        armedAt: _asInt(raw['armedAt']),
        beat: _asInt(raw['beat']),
      );
    }
  }
  return const _GuardMark.idle();
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
