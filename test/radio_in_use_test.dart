import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/transport/radio_in_use.dart';
import 'package:universal_ble/universal_ble.dart';

void main() {
  test('strong hold phrases and the typed error are radio in use', () {
    expect(
      classifyBleConnectFailure(RadioInUseException('held')),
      BleConnectFailure.radioInUse,
    );
    expect(
      classifyBleConnectFailure(
        UniversalBleException(
          code: UniversalBleErrorCode.connectionAlreadyExists,
          message: 'failed',
        ),
      ),
      BleConnectFailure.radioInUse,
    );
    const busy = <String>[
      'Unknown Error 147',
      'UniversalBleException: Code: UniversalBleErrorCode.unknownError, Message: Unknown Error 147, Details: Unknown Error 147',
      'onClientConnectionState() - status=147 connected=false',
      'GATT status 147',
      'Connection Already Exists',
      'UniversalBleErrorCode.connectionAlreadyExists',
      'org.bluez.Error.AlreadyConnected',
      'Device AA:BB is already connected',
      'Device is busy',
      'Device or resource busy',
      'br-connection-busy',
      'Device might be connected but not known to this app',
      'Radio is in use by another app',
      'Connection timeout because the radio is not advertising',
    ];
    for (final text in busy) {
      expect(
        classifyBleConnectFailure(StateError(text)),
        BleConnectFailure.radioInUse,
        reason: text,
      );
      expect(mayDisconnectAfterConnectFailure(StateError(text)), isFalse);
    }
  });

  test('flaky Samsung and ordinary drops are not radio in use', () {
    const ordinary = <String>[
      'Unknown Error 133',
      'GATT_ERROR status 133',
      'status=133',
      'Connection Timeout',
      'status 8',
      'GATT_CONN_TIMEOUT',
      'Failed to connect',
      'Linux connect hard-timeout after 8s',
      'org.bluez.Error.InProgress',
      'le-connection-abort-by-local',
      'deviceNotFound',
      'UniversalBleErrorCode.deviceNotFound',
      'Linux BLE pairing fallback failed',
      'Bluetooth is not powered on',
    ];
    for (final text in ordinary) {
      expect(
        classifyBleConnectFailure(StateError(text)),
        BleConnectFailure.other,
        reason: text,
      );
      expect(mayDisconnectAfterConnectFailure(StateError(text)), isTrue);
    }
    expect(
      classifyBleConnectFailure(
        UniversalBleException(
          code: UniversalBleErrorCode.connectionTimeout,
          message: 'Connection Timeout',
        ),
      ),
      BleConnectFailure.other,
    );
    expect(
      classifyBleConnectFailure(
        UniversalBleException(
          code: UniversalBleErrorCode.connectionFailed,
          message: 'Unknown Error 133',
        ),
      ),
      BleConnectFailure.other,
    );
  });

  test('busy attempt does not disconnect or retry; status 133 still does', () {
    final busy = decideBleConnectAttempt(
      error: StateError('Connection Already Exists'),
      attempt: 1,
      maxAttempts: 3,
    );
    expect(busy.radioInUse, isTrue);
    expect(busy.disconnectPlatformLink, isFalse);
    expect(busy.retry, isFalse);

    final flaky = decideBleConnectAttempt(
      error: StateError('Unknown Error 133'),
      attempt: 1,
      maxAttempts: 3,
    );
    expect(flaky.radioInUse, isFalse);
    expect(flaky.disconnectPlatformLink, isTrue);
    expect(flaky.retry, isTrue);

    final lastFlaky = decideBleConnectAttempt(
      error: StateError('Connection Timeout'),
      attempt: 3,
      maxAttempts: 3,
    );
    expect(lastFlaky.retry, isFalse);
    expect(lastFlaky.disconnectPlatformLink, isTrue);

    final held = decideBleConnectAttempt(
      error: StateError('Unknown Error 147'),
      attempt: 1,
      maxAttempts: 3,
    );
    expect(held.radioInUse, isTrue);
    expect(held.disconnectPlatformLink, isFalse);
    expect(held.retry, isFalse);
  });

  test('Linux connected-by-someone-else is a hold; our own link is not', () {
    expect(
      linuxLinkIsHeldElsewhere(
        locallyConnected: false,
        systemState: BleConnectionState.connected,
      ),
      isTrue,
    );
    expect(
      linuxLinkIsHeldElsewhere(
        locallyConnected: true,
        systemState: BleConnectionState.connected,
      ),
      isFalse,
    );
    expect(
      linuxLinkIsHeldElsewhere(
        locallyConnected: false,
        systemState: BleConnectionState.connecting,
      ),
      isFalse,
    );
    expect(
      linuxLinkIsHeldElsewhere(
        locallyConnected: false,
        systemState: BleConnectionState.disconnected,
      ),
      isFalse,
    );
    expect(
      linuxLinkIsHeldElsewhere(locallyConnected: false, systemState: null),
      isFalse,
    );
  });
}
