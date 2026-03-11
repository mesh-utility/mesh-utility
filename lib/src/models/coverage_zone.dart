import 'package:latlong2/latlong.dart';

class CoverageZone {
  CoverageZone({
    required this.id,
    required this.centerLat,
    required this.centerLng,
    required this.radiusMeters,
    required this.avgRssi,
    required this.avgSnr,
    required this.scanCount,
    required this.lastScanned,
    required this.isDeadZone,
    required this.polygon,
    this.radioId,
  });

  final String id;
  final double centerLat;
  final double centerLng;
  final double radiusMeters;
  final double? avgRssi;
  final double? avgSnr;
  final int scanCount;
  final DateTime lastScanned;
  final bool isDeadZone;
  final List<LatLng> polygon;
  final String? radioId;

  factory CoverageZone.fromJson(Map<String, dynamic> json) {
    List<LatLng> parsePolygon(dynamic raw) {
      if (raw is! List) return [];
      return raw
          .whereType<List>()
          .where((p) => p.length >= 2)
          .map(
            (p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          )
          .toList();
    }

    return CoverageZone(
      id: json['id'].toString(),
      centerLat: (json['centerLat'] as num).toDouble(),
      centerLng: (json['centerLng'] as num).toDouble(),
      radiusMeters: ((json['radiusMeters'] ?? 100) as num).toDouble(),
      avgRssi: (json['avgRssi'] as num?)?.toDouble(),
      avgSnr: (json['avgSnr'] as num?)?.toDouble(),
      scanCount: (json['scanCount'] as num?)?.toInt() ?? 0,
      lastScanned:
          DateTime.tryParse(json['lastScanned']?.toString() ?? '') ??
          DateTime.now(),
      isDeadZone: json['isDeadZone'] == true,
      polygon: parsePolygon(json['polygon']),
      radioId: json['radioId']?.toString(),
    );
  }
}
