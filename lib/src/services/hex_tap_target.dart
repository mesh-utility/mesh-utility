import 'dart:ui' show Offset;

import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';

/// Geographic centre of one filtered coverage zone, cached per dataset.
///
/// Centres come from the zone (the fixed grid centre). Hit-testing projects
/// them with the same camera transform as [CoverageBatchHex] and does not
/// rebuild hex rings.
class CoverageHexCentre {
  const CoverageHexCentre({
    required this.id,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final double latitude;
  final double longitude;
}

/// Finite centres in [zones] order. Built once per dataset identity.
List<CoverageHexCentre> coverageHexCentres(Iterable<CoverageZone> zones) {
  final centres = <CoverageHexCentre>[];
  for (final zone in zones) {
    final lat = zone.centerLat;
    final lng = zone.centerLng;
    if (!lat.isFinite || !lng.isFinite) continue;
    centres.add(CoverageHexCentre(id: zone.id, latitude: lat, longitude: lng));
  }
  return centres;
}

/// Nearest centre inside the view whose projection is within [radius].
///
/// One forward pass. Centres [inView] rejects are skipped, and the scan
/// keeps the closest id. It does not sort and it does not walk scans.
String? nearestCoverageHexCentre({
  required Offset layerPoint,
  required List<CoverageHexCentre> centres,
  required bool Function(double latitude, double longitude) inView,
  required Offset Function(LatLng point) project,
  required double radius,
}) {
  if (!layerPoint.dx.isFinite || !layerPoint.dy.isFinite) return null;
  if (!radius.isFinite || radius < 0) return null;
  String? nearestId;
  var nearestDist = radius;
  for (final centre in centres) {
    if (!inView(centre.latitude, centre.longitude)) continue;
    final projected = project(LatLng(centre.latitude, centre.longitude));
    if (!projected.dx.isFinite || !projected.dy.isFinite) continue;
    final distance = (projected - layerPoint).distance;
    if (distance > nearestDist) continue;
    nearestId = centre.id;
    nearestDist = distance;
  }
  return nearestId;
}
