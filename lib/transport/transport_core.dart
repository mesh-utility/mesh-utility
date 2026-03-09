import 'dart:async';
import 'dart:typed_data';

abstract class Transport {
  Transport(this.name);

  final String name;

  bool get isConnected;

  Stream<Uint8List> get inbound;

  Future<void> connect();

  Future<void> disconnect();

  Future<void> send(Uint8List payload);

  Future<void> dispose() async {}
}

class TransportMessage {
  const TransportMessage({
    required this.transport,
    required this.payload,
    required this.timestamp,
  });

  final String transport;
  final Uint8List payload;
  final DateTime timestamp;
}
