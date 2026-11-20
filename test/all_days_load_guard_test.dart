import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/all_days_load_guard.dart';
import 'package:mesh_utility/src/services/guard_peer_probe.dart';
import 'package:mesh_utility/src/services/reax_database_backend_base.dart';
import 'package:mesh_utility/src/services/settings_change_bus.dart';
import 'package:mesh_utility/src/services/settings_change_channel.dart';
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

class _FakeProbe implements GuardPeerProbe {
  _FakeProbe({this.alive = const <String>{}});

  final Set<String> alive;
  final List<String> asked = <String>[];
  Duration? lastTimeout;

  @override
  Future<bool> isAlive(String ownerId, Duration timeout) async {
    asked.add(ownerId);
    lastTimeout = timeout;
    return alive.contains(ownerId);
  }

  @override
  void serve(String myOwnerId) {}

  @override
  void close() {}
}

class _MemorySettingsChannel implements SettingsChangeChannel {
  void Function(String senderId)? onMessage;
  final List<String> posted = <String>[];

  @override
  void post(String senderId) {
    posted.add(senderId);
    onMessage?.call(senderId);
  }

  @override
  void listen(void Function(String senderId) onMessage) {
    this.onMessage = onMessage;
  }

  @override
  void close() {
    onMessage = null;
  }

  void deliver(String senderId) {
    onMessage?.call(senderId);
  }
}

AllDaysLoadGuard _guard(
  _MemoryDb db, {
  String? ownerId,
  int Function()? nowMs,
  GuardPeerProbe? probe,
}) {
  final guard = AllDaysLoadGuard(
    database: db,
    ownerId: ownerId,
    nowMs: nowMs ?? () => 0,
    probe: probe ?? _FakeProbe(),
  );
  addTearDown(guard.dispose);
  return guard;
}

AppSettings _allDays() {
  return AppSettings.defaults.copyWith(historyDays: 0, deadzoneDays: 0);
}

Map<String, Object?> _record(_MemoryDb db) {
  final raw = db.values[AllDaysLoadGuard.storageKey];
  expect(raw, isA<Map>());
  return Map<String, Object?>.from(raw as Map);
}

void main() {
  group('resolveInterruptedStartup', () {
    test(
      'armed all-days windows fall back while the guard is still armed',
      () async {
        final db = _MemoryDb();
        final probe = _FakeProbe();
        final guard = _guard(db, probe: probe);
        await guard.arm();
        final events = <String>[];

        final resolution = await guard.resolveInterruptedStartup(
          settings: _allDays(),
          saveSettings: (next) async {
            events.add(await guard.isArmed() ? 'save-armed' : 'save-clear');
            expect(next.historyDays, 7);
            expect(next.deadzoneDays, 7);
          },
        );

        expect(events, ['save-armed']);
        expect(probe.asked, isEmpty);
        expect(resolution.fellBackToLast7, isTrue);
        expect(resolution.settings.historyDays, 7);
        expect(resolution.settings.deadzoneDays, 7);
        expect(await guard.isArmed(), isFalse);
      },
    );

    test('falls back only the window that is still all-days', () async {
      final db = _MemoryDb();
      final guard = _guard(db);
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
      final guard = _guard(db);
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
      final guard = _guard(db);
      var saved = false;
      final settings = _allDays();

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

    test(
      'a live other owner keeps All days and leaves the guard armed',
      () async {
        final db = _MemoryDb();
        final started = _guard(db, ownerId: 'other', nowMs: () => 0);
        await started.arm();
        started.dispose();

        final probe = _FakeProbe(alive: {'other'});
        final guard = _guard(
          db,
          ownerId: 'me',
          nowMs: () => AllDaysLoadGuard.staleBeat.inMilliseconds + 1,
          probe: probe,
        );
        var saved = false;

        final resolution = await guard.resolveInterruptedStartup(
          settings: _allDays(),
          saveSettings: (_) async {
            saved = true;
          },
        );

        expect(saved, isFalse);
        expect(probe.asked, ['other']);
        expect(probe.lastTimeout, AllDaysLoadGuard.peerTimeout);
        expect(resolution.fellBackToLast7, isFalse);
        expect(resolution.settings.historyDays, 0);
        expect(resolution.settings.deadzoneDays, 0);
        expect(await guard.isArmed(), isTrue);
        expect(_record(db)['owner'], 'other');
      },
    );

    test(
      'a dead other owner with a stale beat falls back and clears',
      () async {
        final db = _MemoryDb();
        final started = _guard(db, ownerId: 'other', nowMs: () => 1000);
        await started.arm();
        started.dispose();

        final guard = _guard(
          db,
          ownerId: 'me',
          nowMs: () => 1000 + AllDaysLoadGuard.staleBeat.inMilliseconds + 1,
        );
        final events = <String>[];

        final resolution = await guard.resolveInterruptedStartup(
          settings: _allDays(),
          saveSettings: (next) async {
            events.add(await guard.isArmed() ? 'save-armed' : 'save-clear');
            expect(next.historyDays, 7);
            expect(next.deadzoneDays, 7);
          },
        );

        expect(events, ['save-armed']);
        expect(resolution.fellBackToLast7, isTrue);
        expect(resolution.settings.historyDays, 7);
        expect(await guard.isArmed(), isFalse);
      },
    );

    test('a dead other owner with a fresh beat keeps All days', () async {
      final db = _MemoryDb();
      final started = _guard(db, ownerId: 'other', nowMs: () => 5000);
      await started.arm();
      started.dispose();

      final guard = _guard(
        db,
        ownerId: 'me',
        nowMs: () => 5000 + const Duration(seconds: 5).inMilliseconds,
      );
      var saved = false;

      final resolution = await guard.resolveInterruptedStartup(
        settings: _allDays(),
        saveSettings: (_) async {
          saved = true;
        },
      );

      expect(saved, isFalse);
      expect(resolution.fellBackToLast7, isFalse);
      expect(resolution.settings.historyDays, 0);
      expect(resolution.settings.deadzoneDays, 0);
      expect(await guard.isArmed(), isTrue);
      expect(_record(db)['owner'], 'other');
    });

    test('legacy true falls back and clears', () async {
      final db = _MemoryDb();
      final probe = _FakeProbe();
      final guard = _guard(db, probe: probe);
      db.values[AllDaysLoadGuard.storageKey] = true;

      final resolution = await guard.resolveInterruptedStartup(
        settings: _allDays(),
        saveSettings: (next) async {
          expect(await guard.isArmed(), isTrue);
          expect(next.historyDays, 7);
        },
      );

      expect(probe.asked, isEmpty);
      expect(resolution.fellBackToLast7, isTrue);
      expect(resolution.settings.historyDays, 7);
      expect(resolution.settings.deadzoneDays, 7);
      expect(await guard.isArmed(), isFalse);
    });
  });

  group('clear', () {
    test('a non-owner clear is a no-op and the owner can clear', () async {
      final db = _MemoryDb();
      final owner = _guard(db, ownerId: 'owner');
      await owner.arm();
      final other = _guard(db, ownerId: 'other');

      await other.clear();
      expect(await owner.isArmed(), isTrue);
      expect(_record(db)['owner'], 'owner');

      await owner.clear();
      expect(await owner.isArmed(), isFalse);
      expect(db.values[AllDaysLoadGuard.storageKey], isFalse);
    });
  });

  group('heartbeat', () {
    test('beatOnce updates beat for this owner only', () async {
      final db = _MemoryDb();
      var now = 1000;
      final guard = _guard(db, ownerId: 'me', nowMs: () => now);
      await guard.arm();
      expect(_record(db)['beat'], 1000);

      now = 8000;
      await guard.beatOnce();
      expect(_record(db)['beat'], 8000);
      expect(_record(db)['armedAt'], 1000);

      final other = _guard(db, ownerId: 'other', nowMs: () => 50);
      await other.arm();
      now = 99999;
      await guard.beatOnce();
      expect(_record(db)['owner'], 'other');
      expect(_record(db)['beat'], 50);
    });

    testWidgets('the heartbeat timer rewrites beat', (tester) async {
      final db = _MemoryDb();
      var now = 1000;
      final guard = _guard(db, ownerId: 'me', nowMs: () => now);
      await guard.arm();
      expect(_record(db)['beat'], 1000);

      now = 1000 + AllDaysLoadGuard.heartbeatInterval.inMilliseconds;
      await tester.pump(AllDaysLoadGuard.heartbeatInterval);
      expect(_record(db)['beat'], now);
      expect(_record(db)['owner'], 'me');
    });
  });

  group('guardedAllDaysLoad', () {
    test('arms before the load and clears only after success', () async {
      final db = _MemoryDb();
      final guard = _guard(db);
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
      final guard = _guard(db);

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
      final guard = _guard(db);

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
      final guard = _guard(db);
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

  group('broadcast messages', () {
    test('guard ping and pong are small json messages', () {
      final ping = encodeGuardPing(owner: 'owner-a', from: 'tab-b');
      expect(jsonDecode(ping), <String, String>{
        't': 'ping',
        'owner': 'owner-a',
        'from': 'tab-b',
      });
      final parsed = decodeGuardBroadcast(ping);
      expect(parsed, isNotNull);
      expect(parsed!.type, 'ping');
      expect(parsed.owner, 'owner-a');
      expect(parsed.from, 'tab-b');

      final pong = encodeGuardPong('owner-a');
      expect(jsonDecode(pong), <String, String>{
        't': 'pong',
        'owner': 'owner-a',
      });
      expect(decodeGuardBroadcast(pong)!.type, 'pong');
      expect(decodeGuardBroadcast('not json'), isNull);
      expect(decodeGuardBroadcast('{"t":"settings"}'), isNull);
    });

    test(
      'a settings message from another sender reloads and our own is ignored',
      () async {
        final channel = _MemorySettingsChannel();
        final bus = SettingsChangeBus(senderId: 'tab-a', channel: channel);
        addTearDown(bus.close);
        var stored = AppSettings.defaults;
        final reloads = <AppSettings>[];
        bus.listen((from) {
          expect(from, 'tab-b');
          reloads.add(stored);
        });

        stored = AppSettings.defaults.copyWith(historyDays: 0);
        bus.publish();
        expect(reloads, isEmpty);
        expect(channel.posted, <String>['tab-a']);

        channel.deliver('tab-a');
        expect(reloads, isEmpty);

        channel.deliver('tab-b');
        expect(reloads, hasLength(1));
        expect(reloads.single.historyDays, 0);

        final raw = encodeSettingsChanged('tab-b');
        expect(jsonDecode(raw), <String, String>{
          't': 'settings',
          'from': 'tab-b',
        });
        expect(decodeSettingsChangedSender(raw), 'tab-b');
        expect(decodeSettingsChangedSender('{"t":"ping"}'), isNull);
      },
    );
  });
}
