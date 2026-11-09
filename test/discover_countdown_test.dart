import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/transport/transport_core.dart';

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

  @override
  Future<void> dispose() async {
    await _inbound.close();
  }
}

void main() {
  AppState buildState() {
    final state = AppState(
      settingsStore: SettingsStore(),
      localStore: LocalStore(),
      transport: _FakeTransport(),
    );
    state.debugBleReady = true;
    state.bleConnected = true;
    state.settings = state.settings.copyWith(
      discoverWaitSeconds: 40,
      scanIntervalSeconds: 30,
      smartScanEnabled: false,
    );
    return state;
  }

  test('manual countdown ticks before the discover send finishes', () async {
    final gate = Completer<void>();
    final state = buildState();
    state.debugDiscoverSend = () => gate.future;

    final pending = state.forceBleScan();
    await _until(
      () =>
          state.bleNextScanCountdown == 40 &&
          state.bleScanStatus == 'advertising',
    );
    expect(gate.isCompleted, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(gate.isCompleted, isFalse);
    expect(state.bleNextScanCountdown, lessThan(40));
    expect(state.bleNextScanCountdown, greaterThanOrEqualTo(37));

    state.bleConnected = false;
    gate.complete();
    await pending.timeout(const Duration(seconds: 3));
    expect(state.bleScanStatus, 'error');
    expect(state.bleNextScanCountdown, isNull);
    expect(state.bleBusy, isFalse);
    state.dispose();
  });

  test('scan-loop countdown moves while discover is still in flight', () async {
    final gate = Completer<void>();
    final state = buildState();
    state.debugDiscoverSend = () => gate.future;

    final pending = state.toggleBleScan();
    await _until(() => state.bleNextScanCountdown == 30 && !gate.isCompleted);

    expect(state.bleScanning, isTrue);
    expect(gate.isCompleted, isFalse);
    expect(state.bleNextScanCountdown, 30);

    // The due-time ceiling can leave the first one-second tick still showing
    // the full interval. Wait through the next tick.
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(gate.isCompleted, isFalse);
    expect(state.bleNextScanCountdown, lessThan(30));
    expect(state.bleNextScanCountdown, greaterThanOrEqualTo(27));

    state.bleScanning = false;
    state.bleConnected = false;
    gate.complete();
    await pending.timeout(const Duration(seconds: 3));
    expect(state.bleScanStatus, 'error');
    state.dispose();
  });

  test('a failed discover clears the manual countdown', () async {
    final state = buildState();
    state.debugDiscoverSend = () async {
      throw StateError('radio nak');
    };

    await state.forceBleScan();

    expect(state.bleScanStatus, 'error');
    expect(state.bleNextScanCountdown, isNull);
    expect(state.bleBusy, isFalse);
    state.dispose();
  });
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the scan countdown');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
