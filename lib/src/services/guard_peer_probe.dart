import 'dart:convert';

/// Asks whether another tab's all-days load is still running.
///
/// Native and tests use a stub that is never alive. The web app answers over
/// a [BroadcastChannel] named [guardProbeChannelName].
abstract class GuardPeerProbe {
  /// True when [ownerId] answers before [timeout].
  Future<bool> isAlive(String ownerId, Duration timeout);

  /// Answer pings addressed to [myOwnerId].
  void serve(String myOwnerId);

  /// Stop answering and release the channel.
  void close();
}

const String guardProbeChannelName = 'mesh_utility_guard';

String encodeGuardPing({required String owner, required String from}) {
  return jsonEncode(<String, String>{
    't': 'ping',
    'owner': owner,
    'from': from,
  });
}

String encodeGuardPong(String owner) {
  return jsonEncode(<String, String>{'t': 'pong', 'owner': owner});
}

class GuardBroadcast {
  const GuardBroadcast({required this.type, required this.owner, this.from});

  final String type;
  final String owner;
  final String? from;
}

GuardBroadcast? decodeGuardBroadcast(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final type = decoded['t'];
  final owner = decoded['owner'];
  if (type is! String || owner is! String || owner.isEmpty) return null;
  if (type != 'ping' && type != 'pong') return null;
  final from = decoded['from'];
  return GuardBroadcast(
    type: type,
    owner: owner,
    from: from is String ? from : null,
  );
}
