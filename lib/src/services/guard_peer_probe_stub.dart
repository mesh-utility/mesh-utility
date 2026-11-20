import 'package:mesh_utility/src/services/guard_peer_probe.dart';

GuardPeerProbe createGuardPeerProbe() => const StubGuardPeerProbe();

/// Single-process platforms have no peer tab to answer.
class StubGuardPeerProbe implements GuardPeerProbe {
  const StubGuardPeerProbe();

  @override
  Future<bool> isAlive(String ownerId, Duration timeout) async => false;

  @override
  void serve(String myOwnerId) {}

  @override
  void close() {}
}
