import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/reax_database.dart';
import 'package:mesh_utility/src/services/reax_database_backend_base.dart';
import 'package:mesh_utility/src/services/settings_store.dart';

/// Startup marker for an all-days history load.
///
/// The flag is written before the load starts and removed only after that load
/// finishes. A process kill mid-load (the Alpha-20 ANR stop) leaves the flag
/// set, and the next startup falls back to the last 7 days so Settings can
/// be reached. A first upgrade has no flag yet: the all-days choice is kept,
/// and the cached history is processed off the UI isolate.
class AllDaysLoadGuard {
  AllDaysLoadGuard({AppKvDatabase? database}) : _database = database;

  static const storageKey = 'settings:allDaysLoadGuard';
  static const last7Days = 7;

  final AppKvDatabase? _database;

  Future<AppKvDatabase> _db() async {
    final database = _database;
    if (database != null) return database;
    return ReaxDatabase.instance();
  }

  Future<bool> isArmed() async {
    final raw = await (await _db()).get(storageKey);
    return raw == true;
  }

  /// Persist the in-progress marker. Callers must await this before any
  /// all-days cache parse or network fetch.
  Future<void> arm() async {
    await (await _db()).put(storageKey, true);
  }

  Future<void> clear() async {
    await (await _db()).put(storageKey, false);
  }

  /// When a previous all-days load did not finish, move only the all-days
  /// windows to last 7 and persist that before clearing the guard.
  Future<AllDaysStartupResolution> resolveInterruptedStartup({
    required AppSettings settings,
    required Future<void> Function(AppSettings settings) saveSettings,
  }) async {
    if (!await isArmed()) {
      return AllDaysStartupResolution(
        settings: settings,
        fellBackToLast7: false,
      );
    }
    final next = fallbackInterruptedAllDays(settings);
    final changed =
        next.historyDays != settings.historyDays ||
        next.deadzoneDays != settings.deadzoneDays;
    if (changed) {
      await saveSettings(next);
    }
    await clear();
    return AllDaysStartupResolution(
      settings: changed ? next : settings,
      fellBackToLast7: changed,
    );
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
