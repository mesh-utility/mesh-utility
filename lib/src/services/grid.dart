import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

const double hexSize = 0.0007;
const double lngScale = 1.2;
const double rowSpacing = hexSize * 1.5;
const double colSpacing = hexSize * 1.7320508075688772 * lngScale;

({double snapLat, double snapLng}) snapToHexGrid(double lat, double lng) {
  final row = (lat / rowSpacing).round();
  final isOddRow = row.abs().isOdd;
  final offset = isOddRow ? colSpacing / 2 : 0;
  final col = ((lng - offset) / colSpacing).round();
  return (snapLat: row * rowSpacing, snapLng: col * colSpacing + offset);
}

List<LatLng> getHexVertices(double centerLat, double centerLng) {
  final vertices = <LatLng>[];
  for (var i = 0; i < 6; i++) {
    final angleDeg = (60 * i) - 30;
    final angleRad = (math.pi / 180) * angleDeg;
    vertices.add(
      LatLng(
        centerLat + hexSize * math.sin(angleRad),
        centerLng + hexSize * lngScale * math.cos(angleRad),
      ),
    );
  }
  return vertices;
}

String hexKey(double lat, double lng) {
  final snapped = snapToHexGrid(lat, lng);
  return '${snapped.snapLat.toStringAsFixed(6)}:${snapped.snapLng.toStringAsFixed(6)}';
}
