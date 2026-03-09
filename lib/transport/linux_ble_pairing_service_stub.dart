import 'package:mesh_utility/transport/linux_ble_pairing_service_base.dart';

class _LinuxBlePairingServiceStub implements LinuxBlePairingServiceBase {
  @override
  Future<bool> isPairedAndTrusted(String remoteId) async => false;

  @override
  Future<void> removeDevice(
    String remoteId, {
    void Function(String message)? onLog,
  }) async {}

  @override
  Future<bool> pairAndTrust({
    required String remoteId,
    Duration timeout = const Duration(seconds: 45),
    void Function(String message)? onLog,
    Future<String?> Function()? onRequestPin,
    bool proactivePinRetryUsed = false,
    bool removeRetryUsed = false,
  }) async {
    return false;
  }
}

LinuxBlePairingServiceBase createLinuxBlePairingService() {
  return _LinuxBlePairingServiceStub();
}
