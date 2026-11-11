import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

const double hexSize = 0.0007;
const double lngScale = 1.2;
const double rowSpacing = hexSize * 1.5;
const double colSpacing = hexSize * 1.7320508075688772 * lngScale;

({double snapLat, double snapLng}) snapToHexGrid(double lat, double lng) {
  final cell = hexCellAt(lat, lng);
  return (snapLat: cell.lat, snapLng: cell.lng);
}

/// Odd-row pointy-top cell on this grid, or on the same grid scaled by [scale].
///
/// [scale] 1 is the stored coverage cell. Larger scales are parent hexes:
/// spacing and vertex radius both multiply by [scale], and odd parent rows
/// keep the half-column offset. Every fine center belongs to exactly one parent.
({int row, int col, double lat, double lng}) hexCellAt(
  double lat,
  double lng, {
  int scale = 1,
}) {
  final safeScale = scale < 1 ? 1 : scale;
  final rowSpace = rowSpacing * safeScale;
  final colSpace = colSpacing * safeScale;
  final row = (lat / rowSpace).round();
  final col = ((lng - _rowOffset(row, colSpace)) / colSpace).round();
  final center = hexCellCenter(row, col, scale: safeScale);
  return (row: row, col: col, lat: center.lat, lng: center.lng);
}

double _rowOffset(int row, double colSpace) {
  return row.abs().isOdd ? colSpace / 2 : 0.0;
}

/// Center of parent or base cell ([row], [col]) at [scale].
({double lat, double lng}) hexCellCenter(int row, int col, {int scale = 1}) {
  final safeScale = scale < 1 ? 1 : scale;
  final rowSpace = rowSpacing * safeScale;
  final colSpace = colSpacing * safeScale;
  final offset = _rowOffset(row, colSpace);
  return (lat: row * rowSpace, lng: col * colSpace + offset);
}

List<LatLng> getHexVertices(double centerLat, double centerLng) {
  return hexVertices(centerLat, centerLng);
}

/// Hex ring around [centerLat], [centerLng]. [scale] 1 matches [getHexVertices].
///
/// Longitudes are not wrapped, so a ring that crosses ±180 stays a short edge
/// instead of a line across the map.
List<LatLng> hexVertices(double centerLat, double centerLng, {int scale = 1}) {
  final safeScale = scale < 1 ? 1 : scale;
  final size = hexSize * safeScale;
  final vertices = <LatLng>[];
  for (var i = 0; i < 6; i++) {
    final angleDeg = (60 * i) - 30;
    final angleRad = (math.pi / 180) * angleDeg;
    vertices.add(
      LatLng(
        centerLat + size * math.sin(angleRad),
        centerLng + size * lngScale * math.cos(angleRad),
      ),
    );
  }
  return vertices;
}

/// Bounding rectangle of the pointy-top cell ([row], [col]), padded slightly
/// so vertex coordinates survive float rounding. Neighboring hex centers are
/// still outside; callers must also filter with [hexCellAt].
({double south, double north, double west, double east}) hexCellBounds(
  int row,
  int col, {
  int scale = 1,
}) {
  final center = hexCellCenter(row, col, scale: scale);
  final verts = hexVertices(center.lat, center.lng, scale: scale);
  var south = verts.first.latitude;
  var north = verts.first.latitude;
  var west = verts.first.longitude;
  var east = verts.first.longitude;
  for (final v in verts.skip(1)) {
    if (v.latitude < south) south = v.latitude;
    if (v.latitude > north) north = v.latitude;
    if (v.longitude < west) west = v.longitude;
    if (v.longitude > east) east = v.longitude;
  }
  const pad = 1e-7;
  return (
    south: south - pad,
    north: north + pad,
    west: west - pad,
    east: east + pad,
  );
}

String hexKey(double lat, double lng) {
  final snapped = snapToHexGrid(lat, lng);
  return '${snapped.snapLat.toStringAsFixed(6)}:${snapped.snapLng.toStringAsFixed(6)}';
}

/// Index id used by [coverageZonesFromHexDetails] (`hex:row:col`).
String hexIndexId(double lat, double lng) {
  final cell = hexCellAt(lat, lng);
  return 'hex:${cell.row}:${cell.col}';
}

/// Both zone-id forms for a point: the hex index id and the older [hexKey].
Set<String> coverageZoneIdsForPoint(double lat, double lng) {
  return <String>{hexIndexId(lat, lng), hexKey(lat, lng)};
}

/// True when [zoneId] is either id form for this coordinate.
bool coverageZoneIdMatchesPoint(String zoneId, double lat, double lng) {
  return coverageZoneIdsForPoint(lat, lng).contains(zoneId);
}

/// Haversine distance between two points in miles.
double distanceMiles(double lat1, double lng1, double lat2, double lng2) {
  const r = 3958.8;
  final dLat = (lat2 - lat1) * (math.pi / 180.0);
  final dLng = (lng2 - lng1) * (math.pi / 180.0);
  final a =
      (math.sin(dLat / 2) * math.sin(dLat / 2)) +
      math.cos(lat1 * (math.pi / 180.0)) *
          math.cos(lat2 * (math.pi / 180.0)) *
          (math.sin(dLng / 2) * math.sin(dLng / 2));
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
