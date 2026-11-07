import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/all_days_load_guard.dart';
import 'package:mesh_utility/src/services/reax_database_backend_base.dart';
import 'package:mesh_utility/src/services/settings_store.dart';

class _MemoryDb implements AppKvDatabase {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  Future<dynamic> get(String key) async => values[key];

  @override
  Future<void> put(String key, dynamic value) async {
    values[key] = value;
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('resolveInterruptedStartup', () {
    test(
      'armed all-days windows fall back while the guard is still armed',
      () async {
        final db = _MemoryDb();
        final guard = AllDaysLoadGuard(database: db);
        await guard.arm();
        final events = <String>[];

        final resolution = await guard.resolveInterruptedStartup(
          settings: AppSettings.defaults.copyWith(
            historyDays: 0,
            deadzoneDays: 0,
          ),
          saveSettings: (next) async {
            events.add(await guard.isArmed() ? 'save-armed' : 'save-clear');
            expect(next.historyDays, 7);
            expect(next.deadzoneDays, 7);
          },
        );

        expect(events, ['save-armed']);
        expect(resolution.fellBackToLast7, isTrue);
        expect(resolution.settings.historyDays, 7);
        expect(resolution.settings.deadzoneDays, 7);
        expect(await guard.isArmed(), isFalse);
      },
    );

    test('falls back only the window that is still all-days', () async {
      final db = _MemoryDb();
      final guard = AllDaysLoadGuard(database: db);
      await guard.arm();

      final historyOnly = await guard.resolveInterruptedStartup(
        settings: AppSettings.defaults.copyWith(
          historyDays: 0,
          deadzoneDays: 30,
        ),
        saveSettings: (next) async {
          expect(await guard.isArmed(), isTrue);
          expect(next.historyDays, 7);
          expect(next.deadzoneDays, 30);
        },
      );
      expect(historyOnly.fellBackToLast7, isTrue);
      expect(historyOnly.settings.historyDays, 7);
      expect(historyOnly.settings.deadzoneDays, 30);
      expect(await guard.isArmed(), isFalse);

      await guard.arm();
      final deadzoneOnly = await guard.resolveInterruptedStartup(
        settings: AppSettings.defaults.copyWith(
          historyDays: 365,
          deadzoneDays: 0,
        ),
        saveSettings: (next) async {
          expect(await guard.isArmed(), isTrue);
          expect(next.historyDays, 365);
          expect(next.deadzoneDays, 7);
        },
      );
      expect(deadzoneOnly.settings.historyDays, 365);
      expect(deadzoneOnly.settings.deadzoneDays, 7);
      expect(await guard.isArmed(), isFalse);
    });

    test('armed finite windows are kept and the guard is cleared', () async {
      final db = _MemoryDb();
      final guard = AllDaysLoadGuard(database: db);
      await guard.arm();
      var saved = false;
      final settings = AppSettings.defaults.copyWith(
        historyDays: 30,
        deadzoneDays: 365,
      );

      final resolution = await guard.resolveInterruptedStartup(
        settings: settings,
        saveSettings: (_) async {
          saved = true;
        },
      );

      expect(saved, isFalse);
      expect(resolution.fellBackToLast7, isFalse);
      expect(identical(resolution.settings, settings), isTrue);
      expect(await guard.isArmed(), isFalse);
    });

    test('unarmed all-days settings are not truncated', () async {
      final db = _MemoryDb();
      final guard = AllDaysLoadGuard(database: db);
      var saved = false;
      final settings = AppSettings.defaults.copyWith(
        historyDays: 0,
        deadzoneDays: 0,
      );

      final resolution = await guard.resolveInterruptedStartup(
        settings: settings,
        saveSettings: (_) async {
          saved = true;
        },
      );

      expect(saved, isFalse);
      expect(resolution.fellBackToLast7, isFalse);
      expect(resolution.settings.historyDays, 0);
      expect(resolution.settings.deadzoneDays, 0);
      expect(await guard.isArmed(), isFalse);
    });
  });

  group('guardedAllDaysLoad', () {
    test('arms before the load and clears only after success', () async {
      final db = _MemoryDb();
      final guard = AllDaysLoadGuard(database: db);
      var armedDuring = false;

      await guard.guardedAllDaysLoad(
        settings: AppSettings.defaults.copyWith(historyDays: 0),
        load: () async {
          armedDuring = await guard.isArmed();
        },
      );

      expect(armedDuring, isTrue);
      expect(await guard.isArmed(), isFalse);
    });

    test('a thrown failure leaves the guard armed', () async {
      final db = _MemoryDb();
      final guard = AllDaysLoadGuard(database: db);

      await expectLater(
        guard.guardedAllDaysLoad(
          settings: AppSettings.defaults.copyWith(deadzoneDays: 0),
          load: () async {
            expect(await guard.isArmed(), isTrue);
            throw StateError('parse failed');
          },
        ),
        throwsStateError,
      );
      expect(await guard.isArmed(), isTrue);
    });

    test('an incomplete all-days load leaves the guard armed', () async {
      final db = _MemoryDb();
      final guard = AllDaysLoadGuard(database: db);

      await guard.guardedAllDaysLoad(
        settings: AppSettings.defaults.copyWith(
          historyDays: 0,
          deadzoneDays: 14,
        ),
        load: () async {
          expect(await guard.isArmed(), isTrue);
          throw const AllDaysLoadIncomplete();
        },
      );

      expect(await guard.isArmed(), isTrue);
    });

    test('last 7 does not arm the guard', () async {
      final db = _MemoryDb();
      final guard = AllDaysLoadGuard(database: db);
      var armedDuring = true;

      await guard.guardedAllDaysLoad(
        settings: AppSettings.defaults,
        load: () async {
          armedDuring = await guard.isArmed();
        },
      );

      expect(armedDuring, isFalse);
      expect(await guard.isArmed(), isFalse);
    });
  });
}
