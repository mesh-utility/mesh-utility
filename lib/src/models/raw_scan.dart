class RawScan {
  RawScan({
    this.observerId,
    this.nodeId,
    required this.latitude,
    required this.longitude,
    required this.rssi,
    this.snr,
    this.snrIn,
    this.altitude,
    this.timestamp,
    this.receivedAt,
    this.senderName,
    this.receiverName,
    this.radioId,
    this.downloadedFromWorker = false,
  });

  final String? observerId;
  final String? nodeId;
  final double latitude;
  final double longitude;
  final double? rssi;
  final double? snr;
  final double? snrIn;
  final double? altitude;
  final DateTime? timestamp;
  final DateTime? receivedAt;
  final String? senderName;
  final String? receiverName;
  final String? radioId;
  final bool downloadedFromWorker;

  DateTime get effectiveTimestamp => receivedAt ?? timestamp ?? DateTime.now();
  bool get uploadEligible => !downloadedFromWorker;

  RawScan copyWith({bool? downloadedFromWorker}) {
    return RawScan(
      observerId: observerId,
      nodeId: nodeId,
      latitude: latitude,
      longitude: longitude,
      rssi: rssi,
      snr: snr,
      snrIn: snrIn,
      altitude: altitude,
      timestamp: timestamp,
      receivedAt: receivedAt,
      senderName: senderName,
      receiverName: receiverName,
      radioId: radioId,
      downloadedFromWorker: downloadedFromWorker ?? this.downloadedFromWorker,
    );
  }

  factory RawScan.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) {
      if (value is! String || value.isEmpty) return null;
      return DateTime.tryParse(value);
    }

    double? parseNum(dynamic value) {
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    return RawScan(
      observerId: json['observerId']?.toString(),
      nodeId: json['nodeId']?.toString(),
      latitude: (parseNum(json['latitude']) ?? 0),
      longitude: (parseNum(json['longitude']) ?? 0),
      rssi: parseNum(json['rssi']),
      snr: parseNum(json['snr']),
      snrIn: parseNum(json['snrIn']),
      altitude: parseNum(json['altitude']),
      timestamp: parseDate(json['timestamp']),
      receivedAt: parseDate(json['receivedAt']),
      senderName: json['senderName']?.toString(),
      receiverName: json['receiverName']?.toString(),
      radioId: json['radioId']?.toString(),
      downloadedFromWorker: (json['downloadedFromWorker'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'observerId': observerId,
      'nodeId': nodeId,
      'latitude': latitude,
      'longitude': longitude,
      'rssi': rssi,
      'snr': snr,
      'snrIn': snrIn,
      'altitude': altitude,
      'timestamp': timestamp?.toIso8601String(),
      'receivedAt': receivedAt?.toIso8601String(),
      'senderName': senderName,
      'receiverName': receiverName,
      'radioId': radioId,
      'downloadedFromWorker': downloadedFromWorker,
    };
  }
}
