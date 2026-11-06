/// Marker text injected into errors surfaced from the Linux connect stage so
/// that higher-level reconnect logic can distinguish connect-phase failures
/// from pairing-phase failures.
const String linuxConnectStageFailureMarker = 'linux connect stage failure';

/// Returns `true` when [errorText] describes a Linux BLE *connect*-phase
/// failure (BlueZ transport errors, hard timeouts, abort-by-local, etc.)
/// but **not** a pairing failure.
bool isLinuxBleConnectFailureText(String errorText) {
  final lower = errorText.toLowerCase();
  if (isLinuxBlePairingFailureText(errorText)) return false;
  return lower.contains(linuxConnectStageFailureMarker) ||
      lower.contains('| connect |') ||
      lower.contains('linux connect hard-timeout') ||
      lower.contains('org.bluez.error.failed') ||
      lower.contains('org.bluez.error.inprogress') ||
      lower.contains('le-connection-abort-by-local');
}

/// Returns `true` when [errorText] describes a Linux BLE *pairing*-phase
/// failure (authentication errors, bond / trust state issues, etc.).
bool isLinuxBlePairingFailureText(String errorText) {
  final lower = errorText.toLowerCase();
  final isPairingSpecificStateError =
      lower.contains('bad state: no element') &&
      (lower.contains('pair') ||
          lower.contains('bond') ||
          lower.contains('trust'));
  return lower.contains('authenticationfailed') ||
      lower.contains('authentication failed') ||
      lower.contains('notpermitted: not paired') ||
      lower.contains('pairing fallback failed') ||
      lower.contains('linux ble pairing did not complete') ||
      lower.contains('linux ble trust repair did not complete') ||
      isPairingSpecificStateError ||
      isLikelyLinuxBlePairingTimeoutText(errorText);
}

/// Returns `true` when [errorText] looks like a pairing/bond timeout.
bool isLikelyLinuxBlePairingTimeoutText(String errorText) {
  final lower = errorText.toLowerCase();
  return lower.contains('timed out') &&
      (lower.contains('pair') || lower.contains('bond'));
}
