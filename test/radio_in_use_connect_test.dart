import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/transport/protocol.dart';
import 'package:mesh_utility/transport/radio_in_use.dart';
import 'package:mesh_utility/transport/transport_core.dart';

enum _ConnectScript { succeed, busyException, busyText, status133, notFound }

class _FakeTransport extends Transport {
  _FakeTransport(this.script) : super('fake');

  _ConnectScript script;
  int connectCalls = 0;
  bool _connected = false;
  final _inbound = StreamController<Uint8List>.broadcast();

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Future<void> connect() async {
    connectCalls++;
    switch (script) {
      case _ConnectScript.busyException:
        throw RadioInUseException('Connection Already Exists');
      case _ConnectScript.busyText:
        throw StateError(
          'UniversalBleException: Code: '
          'UniversalBleErrorCode.connectionAlreadyExists, '
          'Message: Connection Already Exists',
        );
      case _ConnectScript.status133:
        throw StateError('GATT connect failed: Unknown Error 133');
      case _ConnectScript.notFound:
        throw StateError('UniversalBleErrorCode.deviceNotFound');
      case _ConnectScript.succeed:
        _connected = true;
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<void> send(Uint8List payload) async {
    if (payload.isEmpty || _inbound.isClosed) return;
    final cmd = payload[0];
    if (cmd == cmdAppStart) {
      _inbound.add(Uint8List.fromList(<int>[respCodeSelfInfo]));
    } else if (cmd == cmdGetContacts) {
      _inbound.add(
        Uint8List.fromList(<int>[respCodeContactsStart, 0, 0, 0, 0]),
      );
      _inbound.add(
        Uint8List.fromList(<int>[respCodeEndOfContacts, 0, 0, 0, 0]),
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (!_inbound.isClosed) await _inbound.close();
  }
}

void main() {
  const deviceId = 'AA:BB:CC:DD:EE:FF';

  AppState buildState(_FakeTransport transport) {
    final state = AppState(
      settingsStore: SettingsStore(),
      localStore: LocalStore(),
      transport: transport,
    );
    state.debugBleReady = true;
    state.settings = state.settings.copyWith(
      privacyAccepted: true,
      forceOffline: true,
      bleAutoConnect: false,
      smartScanEnabled: false,
      discoverWaitSeconds: 1,
      scanIntervalSeconds: 40,
      knownBleDeviceIds: const <String>[deviceId],
    );
    state.bleSelectedDeviceId = deviceId;
    return state;
  }

  test(
    'interactive busy connect shows the notice and does not retry',
    () async {
      final transport = _FakeTransport(_ConnectScript.busyException);
      final state = buildState(transport);
      try {
        final ok = await state.connectBle();
        expect(ok, isFalse);
        expect(state.bleConnected, isFalse);
        expect(state.bleConnecting, isFalse);
        expect(state.bleStatus, radioInUseNotice);
        expect(state.debugRadioInUseParked, isTrue);
        expect(state.debugScanReconnectScheduled, isFalse);
        expect(transport.connectCalls, 1);

        final again = await state.connectBle(interactive: false);
        expect(again, isFalse);
        expect(transport.connectCalls, 1);
        expect(state.bleStatus, radioInUseNotice);
      } finally {
        state.dispose();
      }
    },
  );

  test(
    'platform busy text parks the scan loop instead of the fast backoff',
    () async {
      final transport = _FakeTransport(_ConnectScript.busyText);
      final state = buildState(transport);
      try {
        state.debugWantScanLoop();
        await state.debugRunScanLoopReconnectAttempt();
        expect(state.bleStatus, radioInUseNotice);
        expect(state.debugRadioInUseParked, isTrue);
        expect(state.debugScanLoopWanted, isTrue);
        expect(state.debugScanReconnectScheduled, isFalse);
        expect(transport.connectCalls, 1);

        await state.debugRunScanLoopReconnectAttempt();
        expect(transport.connectCalls, 1);
        expect(state.debugScanReconnectScheduled, isFalse);
      } finally {
        state.dispose();
      }
    },
  );

  test(
    'status 133 and device-not-found still arm the fast reconnect',
    () async {
      final transport = _FakeTransport(_ConnectScript.status133);
      final state = buildState(transport);
      try {
        state.debugWantScanLoop();
        await state.debugRunScanLoopReconnectAttempt();
        expect(state.bleStatus, 'BLE connect failed');
        expect(state.debugRadioInUseParked, isFalse);
        expect(state.debugScanLoopWanted, isTrue);
        expect(state.debugScanReconnectScheduled, isTrue);
        expect(transport.connectCalls, 1);
      } finally {
        state.dispose();
      }

      final missing = _FakeTransport(_ConnectScript.notFound);
      final missingState = buildState(missing);
      try {
        missingState.debugWantScanLoop();
        await missingState.debugRunScanLoopReconnectAttempt();
        expect(
          missingState.bleStatus,
          'Device not found – is your radio powered on?',
        );
        expect(missingState.debugRadioInUseParked, isFalse);
        expect(missingState.debugScanReconnectScheduled, isTrue);
        expect(missing.connectCalls, 1);
      } finally {
        missingState.dispose();
      }
    },
  );

  test(
    'successful connect is unchanged when the loop was not parked',
    () async {
      final transport = _FakeTransport(_ConnectScript.succeed);
      final state = buildState(transport);
      try {
        final ok = await state.connectBle();
        expect(ok, isTrue);
        expect(state.bleConnected, isTrue);
        expect(state.bleStatus, startsWith('Connected'));
        expect(state.debugRadioInUseParked, isFalse);
        expect(state.debugScanLoopWanted, isFalse);
        expect(state.debugScanReconnectScheduled, isFalse);
        expect(state.bleScanning, isFalse);
        expect(transport.connectCalls, 1);
      } finally {
        state.dispose();
      }
    },
  );

  test('a normal miss after a hold uses the fast backoff again', () async {
    final transport = _FakeTransport(_ConnectScript.busyText);
    final state = buildState(transport);
    try {
      state.debugWantScanLoop();
      await state.debugRunScanLoopReconnectAttempt();
      expect(state.debugRadioInUseParked, isTrue);
      expect(state.debugScanReconnectScheduled, isFalse);

      transport.script = _ConnectScript.status133;
      final ok = await state.connectBle();
      expect(ok, isFalse);
      expect(state.bleStatus, 'BLE connect failed');
      expect(state.debugRadioInUseParked, isFalse);
      expect(state.debugScanLoopWanted, isTrue);
      expect(state.debugScanReconnectScheduled, isTrue);
      expect(transport.connectCalls, 2);
    } finally {
      state.dispose();
    }
  });

  test('manual Connect after a hold resumes the scan loop', () async {
    final transport = _FakeTransport(_ConnectScript.busyText);
    final state = buildState(transport);
    try {
      state.debugWantScanLoop();
      await state.debugRunScanLoopReconnectAttempt();
      expect(state.debugRadioInUseParked, isTrue);

      transport.script = _ConnectScript.succeed;
      final ok = await state.connectBle();
      expect(ok, isTrue);
      expect(state.bleConnected, isTrue);
      expect(state.debugRadioInUseParked, isFalse);
      expect(state.debugScanLoopWanted, isTrue);
      expect(state.bleScanning, isTrue);
      expect(state.debugScanReconnectScheduled, isFalse);
      expect(transport.connectCalls, 2);
    } finally {
      state.dispose();
    }
  });
}
