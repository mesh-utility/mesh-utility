import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/sync_service.dart';

void main() {
  late Duration now;
  late SyncService sync;
  late int runs;

  setUp(() {
    now = Duration.zero;
    runs = 0;
    sync = SyncService(elapsed: () => now);
    sync.captureInternetTimeAnchor(DateTime.utc(2026, 11, 19, 12));
    sync.onPeriodicSyncDue = () async {
      runs++;
      sync.beginSync();
      sync.completeSync(0);
    };
  });

  tearDown(() => sync.dispose());

  Future<void> minutes(int n) async {
    for (var i = 0; i < n; i++) {
      now += const Duration(minutes: 1);
      await sync.maybeRunPeriodicSync(30);
    }
  }

  test('a finished sync waits the full 30 min interval, not 60 s', () async {
    // Startup/manual sync (the viewport path) finishes.
    sync.beginSync();
    sync.completeSync(3);
    await minutes(29);
    expect(runs, 0);
    await minutes(1);
    expect(runs, 1);
    await minutes(29);
    expect(runs, 1);
    await minutes(1);
    expect(runs, 2);
  });

  test('interval is honored even before an internet time anchor', () async {
    sync = SyncService(elapsed: () => now)
      ..onPeriodicSyncDue = () async => runs++;
    sync.beginSync();
    sync.completeSync(0);
    await minutes(29);
    expect(runs, 0);
  });

  test('a failed periodic sync does not retry on every minute check',
      () async {
    sync.onPeriodicSyncDue = () async {
      runs++;
      sync.beginSync();
      sync.failSync('offline');
    };
    await minutes(1);
    expect(runs, 1);
    await minutes(29);
    expect(runs, 1);
    await minutes(1);
    expect(runs, 2);
  });

  test('manual sync restarts the interval', () async {
    await minutes(1);
    expect(runs, 1);
    await minutes(20);
    sync.beginSync();
    sync.completeSync(0); // manual Sync / on-connect
    await minutes(29);
    expect(runs, 1);
    await minutes(1);
    expect(runs, 2);
  });

  testWidgets('re-configuring with the same interval keeps one timer',
      (tester) async {
    final s = SyncService(elapsed: () => now);
    s.captureInternetTimeAnchor(DateTime.utc(2026, 11, 19, 12));
    var count = 0;
    s.onPeriodicSyncDue = () async {
      count++;
      s.beginSync();
      s.completeSync(0);
    };
    s.beginSync();
    s.completeSync(0);
    // Resume / reconnect / settings save call configure again.
    for (var i = 0; i < 5; i++) {
      s.configure(intervalMinutes: 30, forceOffline: false);
    }
    expect(s.hasPeriodicTimer, isTrue);
    for (var i = 0; i < 61; i++) {
      now += const Duration(minutes: 1);
      await tester.pump(const Duration(minutes: 1));
    }
    expect(count, 2);
    s.configure(intervalMinutes: 30, forceOffline: true);
    expect(s.hasPeriodicTimer, isFalse);
    s.dispose();
  });
}
