import 'dart:async';
import 'dart:js_interop';

import 'package:mesh_utility/src/services/guard_peer_probe.dart';
import 'package:web/web.dart' as web;

GuardPeerProbe createGuardPeerProbe() => WebGuardPeerProbe();

class WebGuardPeerProbe implements GuardPeerProbe {
  WebGuardPeerProbe() {
    try {
      final channel = web.BroadcastChannel(guardProbeChannelName);
      channel.onmessage = ((web.Event event) {
        _handle(event);
      }).toJS;
      _channel = channel;
    } catch (_) {
      _channel = null;
    }
  }

  web.BroadcastChannel? _channel;
  String? _me;
  final Map<String, Completer<bool>> _waiters = <String, Completer<bool>>{};

  void _handle(web.Event event) {
    final data = (event as web.MessageEvent).data?.dartify();
    if (data is! String) return;
    final message = decodeGuardBroadcast(data);
    if (message == null) return;
    if (message.type == 'ping') {
      final me = _me;
      if (me != null && message.owner == me) {
        _post(encodeGuardPong(me));
      }
      return;
    }
    final waiter = _waiters.remove(message.owner);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(true);
    }
  }

  void _post(String payload) {
    _channel?.postMessage(payload.toJS);
  }

  @override
  Future<bool> isAlive(String ownerId, Duration timeout) {
    if (_channel == null || ownerId.isEmpty) {
      return Future<bool>.value(false);
    }
    final previous = _waiters.remove(ownerId);
    if (previous != null && !previous.isCompleted) {
      previous.complete(false);
    }
    final waiter = Completer<bool>();
    _waiters[ownerId] = waiter;
    _post(encodeGuardPing(owner: ownerId, from: _me ?? ''));
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waiters[ownerId], waiter)) {
          _waiters.remove(ownerId);
        }
        return false;
      },
    );
  }

  @override
  void serve(String myOwnerId) {
    _me = myOwnerId;
  }

  @override
  void close() {
    final channel = _channel;
    _channel = null;
    _me = null;
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.complete(false);
    }
    _waiters.clear();
    channel?.close();
  }
}
