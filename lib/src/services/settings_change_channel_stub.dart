import 'package:mesh_utility/src/services/settings_change_channel.dart';

SettingsChangeChannel createSettingsChangeChannel() {
  return const StubSettingsChangeChannel();
}

class StubSettingsChangeChannel implements SettingsChangeChannel {
  const StubSettingsChangeChannel();

  @override
  void post(String senderId) {}

  @override
  void listen(void Function(String senderId) onMessage) {}

  @override
  void close() {}
}
