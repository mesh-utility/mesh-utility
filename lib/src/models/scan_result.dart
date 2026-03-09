class ScanResult {
  ScanResult({
    required this.id,
    required this.observerId,
    required this.nodeId,
    required this.rssi,
    required this.snr,
    required this.snrIn,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.timestamp,
    required this.senderName,
    required this.receiverName,
    required this.radioId,
  });

  final String id;
  final String observerId;
  final String nodeId;
  final double rssi;
  final double? snr;
  final double? snrIn;
  final double latitude;
  final double longitude;
  final double? altitude;
  final DateTime timestamp;
  final String? senderName;
  final String? receiverName;
  final String? radioId;
}
