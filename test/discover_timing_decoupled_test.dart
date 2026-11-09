import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/transport/protocol.dart';
import 'package:mesh_utility/transport/transport_core.dart';

/// The listen loop and the auto-scan due time both read [DateTime.now].
/// [FakeAsync] advances timers without moving that clock, so the 10s wait
/// would never elapse. These tests use the same real-time seams as
/// discover_countdown_test.dart: [AppState.debugDiscoverSend] and a fake
/// transport.
void main() {
  test('manual listen and resend ignore the countdown display', () async {
    final results = await Future.wait([
      _runManual(stompDisplay: false),
      _runManual(stompDisplay: true),
    ]);
    final control = results[0];
    final stomped = results[1];

    expect(control.sends, 2, reason: 'initial send plus one resend');
    expect(stomped.sends, 2, reason: 'stomp must not add or drop a send');
    expect(control.countdownAtSend, 16);
    expect(control.countdownAfterHold, lessThan(16));
    expect(control.countdownAfterHold, greaterThanOrEqualTo(13));
    expect(
      control.countdownDuringListen,
      lessThan(control.countdownAfterHold!),
    );

    expect(control.resendMs, inInclusiveRange(7500, 10500));
    expect(stomped.resendMs, inInclusiveRange(7500, 10500));
    expect(control.listenMs, inInclusiveRange(9800, 13000));
    expect(stomped.listenMs, inInclusiveRange(9800, 13000));
    expect((control.resendMs - stomped.resendMs).abs(), lessThan(2000));
    expect((control.listenMs - stomped.listenMs).abs(), lessThan(2000));
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('auto-loop quiet window ignores the countdown display', () async {
    final results = await Future.wait([
      _runQuiet(stompDisplay: false),
      _runQuiet(stompDisplay: true),
    ]);
    final control = results[0];
    final stomped = results[1];

    expect(control.sends, 1);
    expect(stomped.sends, 1);
    expect(control.discoveries, greaterThan(0));
    expect(stomped.discoveries, greaterThan(0));
    expect(control.countdownAtSend, inInclusiveRange(29, 30));
    expect(control.countdownDuringListen, lessThan(control.countdownAtSend!));
    expect(control.listenMs, inInclusiveRange(1600, 5000));
    expect(stomped.listenMs, inInclusiveRange(1600, 5000));
    expect((control.listenMs - stomped.listenMs).abs(), lessThan(1500));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('auto-loop next cycle stays anchored at the trigger', () async {
    final control = await _runAnchoredCycle(stompDisplay: false);
    final stomped = await _runAnchoredCycle(stompDisplay: true);

    for (final run in [control, stomped]) {
      expect(run.nextAnchor, run.forceDue);
      expect(
        run.nextDue!.difference(run.forceDue!),
        const Duration(seconds: _anchorIntervalSeconds),
        reason: 'the forced due must chain by exactly one interval',
      );
      expect(
        run.deltaFromTriggerMs,
        inInclusiveRange(8000, 160000),
        reason:
            'next send ${run.deltaFromTriggerMs}ms after trigger; '
            'the 1s tick can be late when the suite is busy, '
            'but it must not skip the interval',
      );
      expect(
        run.deltaFromForceSendMs,
        greaterThan(1000),
        reason: 'next send ${run.deltaFromForceSendMs}ms after the force send',
      );
      expect(run.countdownAtForceSend, inInclusiveRange(1, 6));
    }
    expect(
      control.lockedCountdownAtSend,
      inInclusiveRange(0, _anchorIntervalSeconds),
    );
    final countdownAtSend = control.lockedCountdownAtSend;
    if (countdownAtSend != null && countdownAtSend >= 2) {
      expect(control.lockedCountdownAfterHold, lessThan(countdownAtSend));
    }
    expect(
      (control.deltaFromTriggerMs - stomped.deltaFromTriggerMs).abs(),
      lessThan(160000),
    );
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('auto-loop due chain matches scan interval with no drift', () async {
    var stop = false;
    await Future.wait([
      for (final interval in [20, 40, 120])
        _runExactInterval(
          interval,
          shouldStop: () => stop,
          requestStop: () => stop = true,
        ),
    ]);
  }, timeout: const Timeout(Duration(minutes: 20)));

  test('mid-loop scan interval change re-anchors the pending due', () async {
    await Future.wait([
      _runIntervalChange(fromSeconds: 40, toSeconds: 20),
      _runIntervalChange(fromSeconds: 40, toSeconds: 120),
    ]);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

const _anchorIntervalSeconds = 9;
const _anchorSpinMs = 5000;

class _ManualResult {
  const _ManualResult({
    required this.sends,
    required this.resendMs,
    required this.listenMs,
    required this.countdownAtSend,
    required this.countdownAfterHold,
    required this.countdownDuringListen,
  });

  final int sends;
  final int resendMs;
  final int listenMs;
  final int? countdownAtSend;
  final int? countdownAfterHold;
  final int? countdownDuringListen;
}

class _QuietResult {
  const _QuietResult({
    required this.sends,
    required this.listenMs,
    required this.discoveries,
    required this.countdownAtSend,
    required this.countdownDuringListen,
  });

  final int sends;
  final int listenMs;
  final int discoveries;
  final int? countdownAtSend;
  final int? countdownDuringListen;
}

class _AnchorResult {
  const _AnchorResult({
    required this.deltaFromTriggerMs,
    required this.deltaFromForceSendMs,
    required this.countdownAtForceSend,
    required this.lockedCountdownAtSend,
    required this.lockedCountdownAfterHold,
    required this.forceDue,
    required this.nextAnchor,
    required this.nextDue,
  });

  final int deltaFromTriggerMs;
  final int deltaFromForceSendMs;
  final int? countdownAtForceSend;
  final int? lockedCountdownAtSend;
  final int? lockedCountdownAfterHold;
  final DateTime? forceDue;
  final DateTime? nextAnchor;
  final DateTime? nextDue;
}

class _FakeTransport extends Transport {
  _FakeTransport() : super('fake');

  final _inbound = StreamController<Uint8List>.broadcast();

  @override
  bool get isConnected => true;

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> send(Uint8List payload) async {}

  void emit(Uint8List frame) {
    if (!_inbound.isClosed) _inbound.add(frame);
  }

  @override
  Future<void> dispose() async {
    if (!_inbound.isClosed) await _inbound.close();
  }
}

AppState _buildState(
  _FakeTransport transport, {
  required int discoverWaitSeconds,
  required int scanIntervalSeconds,
}) {
  final state = AppState(
    settingsStore: SettingsStore(),
    localStore: LocalStore(),
    transport: transport,
  );
  state.debugBleReady = true;
  state.bleConnected = true;
  state.settings = state.settings.copyWith(
    discoverWaitSeconds: discoverWaitSeconds,
    scanIntervalSeconds: scanIntervalSeconds,
    smartScanEnabled: false,
  );
  return state;
}

Uint8List _discoverResponseFrame() {
  return Uint8List.fromList([
    pushCodeControlData,
    0xF4,
    0xC1,
    0x00,
    controlNodeDiscoverRespMask | 0x02,
    0x30,
    0x71,
    0x8D,
    0x34,
    0x9F,
    0x10,
    0x52,
    0xA9,
    0x30,
    0xAA,
    0xBB,
    0xCC,
    0xDD,
  ]);
}

Future<_ManualResult> _runManual({required bool stompDisplay}) async {
  final transport = _FakeTransport();
  final state = _buildState(
    transport,
    discoverWaitSeconds: 16,
    scanIntervalSeconds: 30,
  );
  final sends = <DateTime>[];
  int? countdownAtSend;
  int? countdownAfterHold;
  int? countdownDuringListen;
  DateTime? firstSendFinished;
  Timer? stomper;
  if (stompDisplay) {
    stomper = Timer.periodic(const Duration(milliseconds: 200), (_) {
      state.bleNextScanCountdown = 0;
    });
  }
  state.debugDiscoverSend = () async {
    sends.add(DateTime.now());
    if (sends.length != 1) return;
    countdownAtSend = state.bleNextScanCountdown;
    if (!stompDisplay) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      countdownAfterHold = state.bleNextScanCountdown;
    }
    firstSendFinished = DateTime.now();
  };
  try {
    final pending = state.forceBleScan();
    if (!stompDisplay) {
      await _until(() => countdownAfterHold != null);
      await _until(() => firstSendFinished != null);
      await Future<void>.delayed(const Duration(seconds: 2));
      countdownDuringListen = state.bleNextScanCountdown;
    }
    await pending.timeout(const Duration(seconds: 20));
    final finished = firstSendFinished;
    expect(finished, isNotNull);
    expect(sends.length, greaterThanOrEqualTo(2));
    return _ManualResult(
      sends: sends.length,
      resendMs: sends[1].difference(finished!).inMilliseconds,
      listenMs: DateTime.now().difference(finished).inMilliseconds,
      countdownAtSend: countdownAtSend,
      countdownAfterHold: countdownAfterHold,
      countdownDuringListen: countdownDuringListen,
    );
  } finally {
    stomper?.cancel();
    state.dispose();
  }
}

Future<_QuietResult> _runQuiet({required bool stompDisplay}) async {
  final transport = _FakeTransport();
  final state = _buildState(
    transport,
    discoverWaitSeconds: 40,
    scanIntervalSeconds: 30,
  );
  final sends = <DateTime>[];
  int? countdownAtSend;
  Timer? stomper;
  if (stompDisplay) {
    stomper = Timer.periodic(const Duration(milliseconds: 200), (_) {
      state.bleNextScanCountdown = 99;
    });
  }
  state.debugDiscoverSend = () async {
    sends.add(DateTime.now());
    countdownAtSend ??= state.bleNextScanCountdown;
  };
  try {
    final pending = state.toggleBleScan();
    await _until(() => state.bleScanStatus == 'waiting');
    final responseAt = DateTime.now();
    transport.emit(_discoverResponseFrame());
    int? countdownDuringListen;
    if (!stompDisplay) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      countdownDuringListen = state.bleNextScanCountdown;
    }
    await pending.timeout(const Duration(seconds: 12));
    return _QuietResult(
      sends: sends.length,
      listenMs: DateTime.now().difference(responseAt).inMilliseconds,
      discoveries: state.bleDiscoveries.length,
      countdownAtSend: countdownAtSend,
      countdownDuringListen: countdownDuringListen,
    );
  } finally {
    stomper?.cancel();
    state.dispose();
  }
}

Future<_AnchorResult> _runAnchoredCycle({required bool stompDisplay}) async {
  final transport = _FakeTransport();
  final state = _buildState(
    transport,
    discoverWaitSeconds: 40,
    scanIntervalSeconds: _anchorIntervalSeconds,
  );
  final sends = <DateTime>[];
  int? countdownAtForceSend;
  int? lockedCountdownAtSend;
  int? lockedCountdownAfterHold;
  DateTime? forceDue;
  DateTime? nextAnchor;
  DateTime? nextDue;
  var respondedForSend = 0;
  final responder = Timer.periodic(const Duration(milliseconds: 40), (_) {
    if (state.bleScanStatus != 'waiting') return;
    if (respondedForSend >= sends.length) return;
    respondedForSend = sends.length;
    transport.emit(_discoverResponseFrame());
  });
  Timer? stomper;
  if (stompDisplay) {
    stomper = Timer.periodic(const Duration(milliseconds: 200), (_) {
      state.bleNextScanCountdown = 99;
    });
  }
  state.debugDiscoverSend = () async {
    sends.add(DateTime.now());
    if (sends.length == 2) {
      countdownAtForceSend = state.bleNextScanCountdown;
      forceDue = state.debugNextAutoScanDueAt;
    }
    if (sends.length == 3) {
      nextAnchor = state.debugLastAutoScanTriggerAt;
      nextDue = state.debugNextAutoScanDueAt;
      lockedCountdownAtSend = state.bleNextScanCountdown;
      if (!stompDisplay) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        lockedCountdownAfterHold = state.bleNextScanCountdown;
      }
      state.bleConnected = false;
      state.bleScanning = false;
    }
  };
  try {
    await state.toggleBleScan().timeout(const Duration(seconds: 8));
    expect(sends, hasLength(1));

    var arm = true;
    DateTime? triggerAt;
    state.addListener(() {
      if (!arm) return;
      if (!StackTrace.current.toString().contains('forceBleScan')) return;
      arm = false;
      triggerAt = DateTime.now();
      final spin = Stopwatch()..start();
      while (spin.elapsedMilliseconds < _anchorSpinMs) {}
    });

    await state.forceBleScan().timeout(const Duration(seconds: 15));
    expect(sends, hasLength(2));
    expect(triggerAt, isNotNull, reason: 'force scan did not notify');
    await _until(
      () => sends.length >= 3,
      timeout: const Duration(seconds: 150),
      reason: 'the cycle after the forced scan',
    );
    await _until(() => !state.bleBusy, timeout: const Duration(seconds: 5));
    final nextSend = sends[2];
    return _AnchorResult(
      deltaFromTriggerMs: nextSend.difference(triggerAt!).inMilliseconds,
      deltaFromForceSendMs: nextSend.difference(sends[1]).inMilliseconds,
      countdownAtForceSend: countdownAtForceSend,
      lockedCountdownAtSend: lockedCountdownAtSend,
      lockedCountdownAfterHold: lockedCountdownAfterHold,
      forceDue: forceDue,
      nextAnchor: nextAnchor,
      nextDue: nextDue,
    );
  } finally {
    stomper?.cancel();
    responder.cancel();
    state.dispose();
  }
}

Future<void> _until(
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 3),
  String reason = 'discover timing condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

const _exactCyclesAfterFirst = 5;

class _DueSample {
  const _DueSample({
    required this.sendAt,
    required this.lastTrigger,
    required this.nextDue,
  });

  final DateTime sendAt;
  final DateTime lastTrigger;
  final DateTime nextDue;
}

class _MemorySettingsStore extends SettingsStore {
  _MemorySettingsStore(this.value);

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async {
    value = settings;
  }
}

/// Cycles after the first must chain previousDue + interval.
///
/// Re-anchoring each cycle at [DateTime.now] would add that cycle's tick
/// lateness to every later due. The scheduled chain must not.
void _expectExactSamples(int intervalSeconds, List<_DueSample> samples) {
  expect(samples, isNotEmpty);
  final interval = Duration(seconds: intervalSeconds);
  final first = samples.first;
  expect(first.nextDue.difference(first.lastTrigger), interval);
  expect(
    first.lastTrigger.difference(first.sendAt).inMilliseconds.abs(),
    lessThan(2000),
    reason:
        'first cycle anchor is ${first.lastTrigger.difference(first.sendAt).inMilliseconds}ms '
        'from the send; a future pre-set due would be about '
        '${intervalSeconds}s ahead and the next wait would be two intervals',
  );

  for (var i = 1; i < samples.length; i++) {
    final sample = samples[i];
    final previous = samples[i - 1];
    expect(
      sample.lastTrigger,
      previous.nextDue,
      reason: 'cycle $i anchor must be the previous due',
    );
    expect(sample.nextDue.difference(sample.lastTrigger), interval);
    expect(
      sample.nextDue.difference(previous.nextDue),
      interval,
      reason: 'due $i drifted off ${intervalSeconds}s',
    );
  }

  if (samples.length >= 2) {
    final firstGapMs = samples[1].sendAt
        .difference(samples[0].sendAt)
        .inMilliseconds;
    expect(
      firstGapMs,
      greaterThan(intervalSeconds * 1000 - 500),
      reason:
          'first gap ${firstGapMs}ms for ${intervalSeconds}s; '
          'the immediate start cycle must not leave a double interval',
    );
  }

  for (var i = 2; i < samples.length; i++) {
    final gapMs = samples[i].sendAt
        .difference(samples[i - 1].sendAt)
        .inMilliseconds;
    final latenessMs = samples[i].sendAt
        .difference(samples[i].lastTrigger)
        .inMilliseconds;
    final previousLatenessMs = samples[i - 1].sendAt
        .difference(samples[i - 1].lastTrigger)
        .inMilliseconds;
    // A starved 1s tick can miss the due by seconds. Only score the send
    // against the 200ms budget when both cycles actually ran on time.
    if (latenessMs.abs() > 200 || previousLatenessMs.abs() > 200) {
      continue;
    }
    expect(
      gapMs,
      inInclusiveRange(
        intervalSeconds * 1000 - 200,
        intervalSeconds * 1000 + 200,
      ),
      reason:
          'on-phase send gap $i was ${gapMs}ms for ${intervalSeconds}s '
          '(tick lateness ${latenessMs}ms, previous ${previousLatenessMs}ms)',
    );
  }

  if (samples.length < _exactCyclesAfterFirst + 1) return;

  final span = samples.last.nextDue.difference(samples.first.nextDue);
  expect(span, Duration(seconds: intervalSeconds * (samples.length - 1)));

  var bugDue = samples.first.nextDue;
  var walked = Duration.zero;
  for (var i = 1; i < samples.length; i++) {
    final lateness = samples[i].sendAt.difference(samples[i].lastTrigger);
    bugDue = bugDue.add(lateness).add(interval);
    walked += lateness;
  }
  expect(bugDue.difference(samples.last.nextDue), walked);
  // Re-anchoring at each send would move the final due by [walked]. A quiet
  // tick can be only a few milliseconds late; that is enough to show the
  // scheduled chain did not follow it. Exact zero lateness still leaves the
  // due equalities above as the proof.
  if (walked != Duration.zero) {
    expect(
      samples.last.nextDue,
      isNot(bugDue),
      reason:
          're-anchoring at each send would have walked '
          '${walked.inMicroseconds}us across ${samples.length - 1} cycles; '
          'the scheduled span stayed exact',
    );
  }
}

Future<void> _runExactInterval(
  int intervalSeconds, {
  required bool Function() shouldStop,
  required void Function() requestStop,
}) async {
  final transport = _FakeTransport();
  final state = _buildState(
    transport,
    discoverWaitSeconds: 40,
    scanIntervalSeconds: intervalSeconds,
  );
  final samples = <_DueSample>[];
  const totalCycles = _exactCyclesAfterFirst + 1;
  String? scheduleError;
  var respondedForSend = 0;
  final responder = Timer.periodic(const Duration(milliseconds: 40), (_) {
    if (state.bleScanStatus != 'waiting') return;
    if (respondedForSend >= samples.length) return;
    respondedForSend = samples.length;
    transport.emit(_discoverResponseFrame());
  });
  state.debugDiscoverSend = () async {
    if (samples.length >= totalCycles) return;
    final lastTrigger = state.debugLastAutoScanTriggerAt;
    final nextDue = state.debugNextAutoScanDueAt;
    if (lastTrigger == null || nextDue == null) {
      scheduleError = 'cycle scheduled no anchor=$lastTrigger due=$nextDue';
      state.bleConnected = false;
      state.bleScanning = false;
      return;
    }
    samples.add(
      _DueSample(
        sendAt: DateTime.now(),
        lastTrigger: lastTrigger,
        nextDue: nextDue,
      ),
    );
    if (samples.length >= totalCycles) {
      state.bleConnected = false;
      state.bleScanning = false;
    }
  };

  late final Future<void> started;
  try {
    started = state.toggleBleScan();
    await _until(
      () => samples.isNotEmpty || scheduleError != null || shouldStop(),
      timeout: const Duration(seconds: 8),
      reason: 'the first ${intervalSeconds}s discover send',
    );
    if (scheduleError != null) {
      fail(scheduleError!);
    }
    // One starved 1s tick while the rest of the suite is running can add
    // more than a minute. The scheduled due chain is still exact.
    final deadline = DateTime.now().add(
      Duration(seconds: intervalSeconds * _exactCyclesAfterFirst + 240),
    );
    var checked = 0;
    while (samples.length < totalCycles && !shouldStop()) {
      if (scheduleError != null) {
        fail(scheduleError!);
      }
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'timed out after ${samples.length} cycles '
          'for a ${intervalSeconds}s scan interval',
        );
      }
      if (samples.length > checked) {
        _expectExactSamples(intervalSeconds, samples);
        checked = samples.length;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!shouldStop()) {
      expect(samples, hasLength(totalCycles));
      await _until(
        () => !state.bleBusy,
        timeout: const Duration(seconds: 15),
        reason: 'the last ${intervalSeconds}s cycle to finish',
      );
    }
  } catch (_) {
    requestStop();
    rethrow;
  } finally {
    state.bleScanning = false;
    state.bleConnected = false;
    responder.cancel();
    final busyDeadline = DateTime.now().add(const Duration(seconds: 8));
    while (state.bleBusy && DateTime.now().isBefore(busyDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    try {
      await started.timeout(const Duration(seconds: 8));
    } catch (_) {}
    state.dispose();
  }
}

Future<void> _runIntervalChange({
  required int fromSeconds,
  required int toSeconds,
}) async {
  final transport = _FakeTransport();
  final initial = AppSettings.defaults.copyWith(
    privacyAccepted: true,
    forceOffline: true,
    smartScanEnabled: false,
    discoverWaitSeconds: 40,
    scanIntervalSeconds: fromSeconds,
  );
  final store = _MemorySettingsStore(initial);
  final state = AppState(
    settingsStore: store,
    localStore: LocalStore(),
    transport: transport,
  );
  state.debugBleReady = true;
  state.bleConnected = true;
  state.settings = initial;

  final sends = <DateTime>[];
  DateTime? lastTrigger;
  DateTime? dueBefore;
  DateTime? dueAfter;
  int? countdownAfter;
  var respondedForSend = 0;
  final responder = Timer.periodic(const Duration(milliseconds: 40), (_) {
    if (state.bleScanStatus != 'waiting') return;
    if (respondedForSend >= sends.length) return;
    respondedForSend = sends.length;
    transport.emit(_discoverResponseFrame());
  });
  state.debugDiscoverSend = () async {
    sends.add(DateTime.now());
    if (sends.length != 1) return;
    lastTrigger = state.debugLastAutoScanTriggerAt;
    dueBefore = state.debugNextAutoScanDueAt;
    await state.updateSettings(
      state.settings.copyWith(scanIntervalSeconds: toSeconds),
    );
    dueAfter = state.debugNextAutoScanDueAt;
    countdownAfter = state.bleNextScanCountdown;
  };

  try {
    await state.toggleBleScan().timeout(const Duration(seconds: 15));
    expect(
      sends,
      hasLength(1),
      reason: 'changing the interval must not send another discover',
    );
    expect(lastTrigger, isNotNull);
    expect(dueBefore, isNotNull);
    expect(dueAfter, isNotNull);
    expect(dueBefore!.difference(lastTrigger!), Duration(seconds: fromSeconds));
    expect(
      dueAfter!.difference(lastTrigger!),
      Duration(seconds: toSeconds),
      reason:
          'pending due must be last trigger + ${toSeconds}s, '
          'not + ${fromSeconds}s',
    );
    expect(state.debugLastAutoScanTriggerAt, lastTrigger);
    if (toSeconds > fromSeconds) {
      expect(dueAfter!.isAfter(dueBefore!), isTrue);
    } else {
      expect(dueAfter!.isBefore(dueBefore!), isTrue);
    }
    expect(countdownAfter, inInclusiveRange(toSeconds - 2, toSeconds));
    expect(state.settings.scanIntervalSeconds, toSeconds);
    expect(store.value.scanIntervalSeconds, toSeconds);

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(
      sends,
      hasLength(1),
      reason:
          'the next tick must not start a discover just because the interval changed',
    );
    expect(state.debugNextAutoScanDueAt, dueAfter);
    expect(state.debugLastAutoScanTriggerAt, lastTrigger);
  } finally {
    responder.cancel();
    state.bleScanning = false;
    state.bleConnected = false;
    state.dispose();
  }
}
