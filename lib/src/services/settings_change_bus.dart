import 'dart:math';

import 'package:mesh_utility/src/services/settings_change_channel.dart';
import 'package:mesh_utility/src/services/settings_change_channel_stub.dart'
    if (dart.library.io) 'package:mesh_utility/src/services/settings_change_channel_stub.dart'
    if (dart.library.js_interop) 'package:mesh_utility/src/services/settings_change_channel_web.dart'
    as settings_channel;

/// Posts a settings-saved notice and ignores notices this instance sent.
class SettingsChangeBus {
  SettingsChangeBus({String? senderId, SettingsChangeChannel? channel})
    : senderId = senderId ?? _newSenderId(),
      _channel = channel ?? settings_channel.createSettingsChangeChannel() {
    _channel.listen((from) {
      if (from == this.senderId) return;
      _listener?.call(from);
    });
  }

  final String senderId;
  final SettingsChangeChannel _channel;
  void Function(String from)? _listener;

  void publish() {
    _channel.post(senderId);
  }

  void listen(void Function(String from) onRemote) {
    _listener = onRemote;
  }

  void close() {
    _listener = null;
    _channel.close();
  }
}

String _newSenderId() {
  final random = Random();
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final noise = random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0');
  final extra = random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0');
  return '$time-$noise$extra';
}
