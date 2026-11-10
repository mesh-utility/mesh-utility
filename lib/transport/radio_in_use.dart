import 'package:universal_ble/universal_ble.dart';

/// Shown when another app already holds the MeshCore radio.
const String radioInUseNotice = 'Radio is in use by another app';

/// Connect failed because another central already holds the radio.
///
/// Callers branch on this type, or on [classifyBleConnectFailure], instead of
/// matching platform strings at each call site.
class RadioInUseException implements Exception {
  RadioInUseException([this.cause]);

  final Object? cause;

  @override
  String toString() {
    if (cause == null) return radioInUseNotice;
    return '$radioInUseNotice ($cause)';
  }
}

/// Why a connect attempt failed, for app-level reconnect policy.
enum BleConnectFailure {
  /// Strong evidence another app holds the radio. Do not disconnect it and
  /// do not retry on a short backoff.
  radioInUse,

  /// Flaky link, radio off, out of range, or any other failure. The existing
  /// reconnect backoff still applies.
  other,
}

BleConnectFailure classifyBleConnectFailure(Object error) {
  if (isRadioHeldElsewhereError(error)) return BleConnectFailure.radioInUse;
  return BleConnectFailure.other;
}

/// True only when [error] is strong evidence the radio is held elsewhere.
///
/// Android GATT 133 and HCI connection timeout (status 8) are not enough.
/// Both happen on a normal Samsung connect and when the radio is simply off
/// or out of range. Those stay on the existing reconnect backoff.
///
/// GATT status 147 (`Unknown Error 147`) is what Samsung reports when another
/// central already holds the T-Deck. Treat it as in-use and do not retry.
bool isRadioHeldElsewhereError(Object error) {
  if (error is RadioInUseException) return true;
  if (error is UniversalBleException &&
      error.code == UniversalBleErrorCode.connectionAlreadyExists) {
    return true;
  }
  return isRadioHeldElsewhereText(error.toString());
}

/// Phrase check shared by Android and Linux connect errors.
///
/// A bare timeout counts only together with an explicit "not advertising"
/// note. Status 133 / `GATT_ERROR` / `Unknown Error 133` do not match.
bool isRadioHeldElsewhereText(String errorText) {
  final lower = errorText.toLowerCase();
  if (_hasStrongRadioHoldPhrase(lower)) return true;
  return _isTimeoutBecauseNotAdvertising(lower);
}

/// Whether a failed attempt may call platform disconnect.
///
/// Disconnecting the target id drops another app's BlueZ connection, and on
/// some Android stacks it can kick the other central. A busy failure only
/// clears local subscriptions.
bool mayDisconnectAfterConnectFailure(Object error) {
  return !isRadioHeldElsewhereError(error);
}

/// Policy for one failed connect attempt.
class BleConnectAttemptDecision {
  const BleConnectAttemptDecision({
    required this.radioInUse,
    required this.disconnectPlatformLink,
    required this.retry,
  });

  final bool radioInUse;
  final bool disconnectPlatformLink;
  final bool retry;
}

BleConnectAttemptDecision decideBleConnectAttempt({
  required Object error,
  required int attempt,
  required int maxAttempts,
}) {
  if (isRadioHeldElsewhereError(error)) {
    return const BleConnectAttemptDecision(
      radioInUse: true,
      disconnectPlatformLink: false,
      retry: false,
    );
  }
  return BleConnectAttemptDecision(
    radioInUse: false,
    disconnectPlatformLink: true,
    retry: attempt < maxAttempts,
  );
}

/// Linux BlueZ `Connected: yes` is system-wide. If this session does not own
/// the link, another client does. Do not disconnect it.
///
/// [systemState] null means the check failed. That is not evidence of a hold.
bool linuxLinkIsHeldElsewhere({
  required bool locallyConnected,
  required BleConnectionState? systemState,
}) {
  if (locallyConnected) return false;
  return systemState == BleConnectionState.connected;
}

bool _hasStrongRadioHoldPhrase(String lower) {
  const phrases = <String>[
    'connection already exists',
    'connectionalreadyexists',
    'already connected',
    'alreadyconnected',
    'device is busy',
    'device busy',
    'resource busy',
    'connection busy',
    'connection-busy',
    'in use by another',
    'another application',
    'another app',
    'another central',
    'not known to this app',
    'held by another',
  ];
  for (final phrase in phrases) {
    if (lower.contains(phrase)) return true;
  }
  if (_isGattStatus147(lower)) return true;
  return false;
}

/// Samsung reports 147 (0x93) when the link is already held elsewhere.
bool _isGattStatus147(String lower) {
  if (lower.contains('unknown error 147')) return true;
  if (lower.contains('status=147')) return true;
  if (lower.contains('status 147')) return true;
  if (lower.contains('gatt_conn_fail_establish') && lower.contains('147')) {
    return true;
  }
  return RegExp(r'(?:\bgatt\b|error)[^0-9]{0,24}147\b').hasMatch(lower);
}

/// "Connection timeout" alone is a radio that is off, out of range, or not
/// answering. It is busy only when the error also says the radio is not
/// advertising, which is how a companion stops advertising while another
/// central holds it.
bool _isTimeoutBecauseNotAdvertising(String lower) {
  final timedOut =
      lower.contains('connection timeout') ||
      lower.contains('timed out') ||
      lower.contains('timeout');
  if (!timedOut) return false;
  return lower.contains('not advertising') ||
      lower.contains('isn\'t advertising') ||
      lower.contains('notadvertising');
}
