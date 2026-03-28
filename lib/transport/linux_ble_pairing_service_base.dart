import 'dart:async';

abstract class LinuxBlePairingServiceBase {
  Future<bool> isBluetoothctlAvailable();
  Future<bool> isPairedAndTrusted(String remoteId);
  Future<bool> trustDevice(
    String remoteId, {
    void Function(String message)? onLog,
  });
  Future<void> disconnectDevice(
    String remoteId, {
    void Function(String message)? onLog,
  });
  Future<bool> connectDevice(
    String remoteId, {
    void Function(String message)? onLog,
  });
  Future<String?> lookupDeviceDisplayName(
    String remoteId, {
    void Function(String message)? onLog,
  });
  Future<void> removeDevice(
    String remoteId, {
    void Function(String message)? onLog,
  });
  Future<bool> pairAndTrust({
    required String remoteId,
    Duration timeout,
    void Function(String message)? onLog,
    Future<String?> Function()? onRequestPin,
  });
}
