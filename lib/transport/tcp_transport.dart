import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_utility/transport/transport_core.dart';

class TcpTransport extends Transport {
  TcpTransport({required this.host, required this.port}) : super('tcp');

  final String host;
  final int port;

  final _inboundController = StreamController<Uint8List>.broadcast();
  Socket? _socket;

  @override
  bool get isConnected => _socket != null;

  @override
  Stream<Uint8List> get inbound => _inboundController.stream;

  @override
  Future<void> connect() async {
    _socket = await Socket.connect(host, port);
    _socket!.listen(
      (data) => _inboundController.add(Uint8List.fromList(data)),
      onDone: () => _socket = null,
      onError: (_) => _socket = null,
      cancelOnError: true,
    );
  }

  @override
  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
  }

  @override
  Future<void> send(Uint8List payload) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('TCP transport is not connected');
    }
    socket.add(payload);
    await socket.flush();
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _inboundController.close();
  }
}
