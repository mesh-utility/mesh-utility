import 'dart:async';

abstract class LinuxBlePairingServiceBase {
  Future<bool> isPairedAndTrusted(String remoteId);
  Future<void> removeDevice(String remoteId, {void Function(String message)? onLog});

  Future<bool> pairAndTrust({
    required String remoteId,
    Duration timeout = const Duration(seconds: 45),
    void Function(String message)? onLog,
    Future<String?> Function()? onRequestPin,
    bool proactivePinRetryUsed = false,
    bool removeRetryUsed = false,
  });
}
