import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_utility/transport/transport_core.dart';

class UsbTransport extends Transport {
  UsbTransport() : super('usb');

  final _inboundController = StreamController<Uint8List>.broadcast();
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get inbound => _inboundController.stream;

  @override
  Future<void> connect() async {
    // TODO: integrate platform USB plugin and device selection.
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<void> send(Uint8List payload) async {
    if (!_connected) {
      throw StateError('USB transport is not connected');
    }
    // TODO: write payload to USB endpoint.
  }

  Future<void> pushInbound(Uint8List payload) async {
    if (!_inboundController.isClosed) {
      _inboundController.add(payload);
    }
  }

  @override
  Future<void> dispose() async {
    await _inboundController.close();
  }
}
