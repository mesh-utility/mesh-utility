import 'dart:convert';

/// Cross-tab notice that settings were saved. Native is a no-op.
abstract class SettingsChangeChannel {
  void post(String senderId);

  void listen(void Function(String senderId) onMessage);

  void close();
}

const String settingsChangeChannelName = 'mesh_utility_settings';

String encodeSettingsChanged(String senderId) {
  return jsonEncode(<String, String>{'t': 'settings', 'from': senderId});
}

/// Sender id from a settings broadcast, or null when [raw] is not one.
String? decodeSettingsChangedSender(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['t'] != 'settings') return null;
  final from = decoded['from'];
  if (from is! String || from.isEmpty) return null;
  return from;
}
