import 'dart:js_interop';

import 'package:mesh_utility/src/services/settings_change_channel.dart';
import 'package:web/web.dart' as web;

SettingsChangeChannel createSettingsChangeChannel() =>
    WebSettingsChangeChannel();

class WebSettingsChangeChannel implements SettingsChangeChannel {
  WebSettingsChangeChannel() {
    try {
      final channel = web.BroadcastChannel(settingsChangeChannelName);
      channel.onmessage = ((web.Event event) {
        _handle(event);
      }).toJS;
      _channel = channel;
    } catch (_) {
      _channel = null;
    }
  }

  web.BroadcastChannel? _channel;
  void Function(String senderId)? _listener;

  void _handle(web.Event event) {
    final data = (event as web.MessageEvent).data?.dartify();
    if (data is! String) return;
    final from = decodeSettingsChangedSender(data);
    if (from == null) return;
    _listener?.call(from);
  }

  @override
  void post(String senderId) {
    _channel?.postMessage(encodeSettingsChanged(senderId).toJS);
  }

  @override
  void listen(void Function(String senderId) onMessage) {
    _listener = onMessage;
  }

  @override
  void close() {
    final channel = _channel;
    _channel = null;
    _listener = null;
    channel?.close();
  }
}
