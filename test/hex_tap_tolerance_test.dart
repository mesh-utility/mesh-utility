import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/hex_detail.dart';
import 'package:mesh_utility/src/widgets/coverage_hex_batch_layer.dart';

CoverageBatchHex _hexFromCell(int row, int col, {String? hitId}) {
  final detail = HexDetail(row: row, col: col, scanCount: 1, lastTs: 1);
  final zone = coverageZonesFromHexDetails([detail]).single;
  return CoverageBatchHex(
    points: zone.polygon,
    hitId: hitId ?? zone.id,
    fill: const Color(0x4433AA55),
    border: const Color(0xFF33AA55),
    center: LatLng(zone.centerLat, zone.centerLng),
  );
}

MapCamera _camera(LatLng center, double zoom) {
  return MapCamera(
    crs: const Epsg3857(),
    center: center,
    zoom: zoom,
    rotation: 0,
    nonRotatedSize: const Size(1000, 1000),
  );
}

void main() {
  final origin = hexCellAt(40.79, -77.86);
  final hexA = _hexFromCell(origin.row, origin.col, hitId: 'A');
  final hexB = _hexFromCell(origin.row, origin.col + 1, hitId: 'B');
  final mapCenter = LatLng(origin.lat, origin.lng);

  test('zoom 12: touch radius hits 6, 10 and 16 px from center', () {
    final camera = _camera(mapCenter, 12);
    Offset project(LatLng p) => coverageHexLayerOffset(camera, p);
    final center = project(hexA.center);
    for (final px in <double>[6, 10, 16]) {
      expect(
        hitTestCoverageBatchHexesNearest(
          center + Offset(px, 0),
          [hexA],
          project,
          radius: kHexTapRadiusTouch,
        ),
        'A',
        reason: '$px px from center',
      );
    }
    expect(
      hitTestCoverageBatchHexesNearest(
        center + const Offset(40, 0),
        [hexA],
        project,
        radius: kHexTapRadiusTouch,
      ),
      isNull,
    );
  });

  test('zoom 10: nearer center wins', () {
    final camera = _camera(mapCenter, 10);
    Offset project(LatLng p) => coverageHexLayerOffset(camera, p);
    final a = project(hexA.center);
    final b = project(hexB.center);
    final away = a - b;
    final tap = a + away / away.distance * 8;
    expect((tap - a).distance, lessThan((tap - b).distance));
    expect(
      hitTestCoverageBatchHexesNearest(
        tap,
        [hexA, hexB],
        project,
        radius: kHexTapRadiusTouch,
      ),
      'A',
    );
    expect(
      hitTestCoverageBatchHexesNearest(
        b + (b - a) / (b - a).distance * 8,
        [hexA, hexB],
        project,
        radius: kHexTapRadiusTouch,
      ),
      'B',
    );
  });

  test('zoom 16: exact hit returns the containing hex', () {
    final camera = _camera(mapCenter, 16);
    Offset project(LatLng p) => coverageHexLayerOffset(camera, p);
    final ring = hexA.points;
    final edgeMid = LatLng(
      (ring[0].latitude + ring[1].latitude) / 2,
      (ring[0].longitude + ring[1].longitude) / 2,
    );
    final nearEdge = LatLng(
      hexA.center.latitude * 0.15 + edgeMid.latitude * 0.85,
      hexA.center.longitude * 0.15 + edgeMid.longitude * 0.85,
    );
    final tap = project(nearEdge);
    expect(hitTestCoverageBatchHexesOnScreen(tap, [hexA, hexB], project), 'A');
    expect(
      hitTestCoverageBatchHexesNearest(
        tap,
        [hexA, hexB],
        project,
        radius: kHexTapRadiusTouch,
      ),
      'A',
    );
  });

  test('mouse radius misses at 16 px where touch hits', () {
    final camera = _camera(mapCenter, 12);
    Offset project(LatLng p) => coverageHexLayerOffset(camera, p);
    final tap = project(hexA.center) + const Offset(16, 0);
    expect(
      hitTestCoverageBatchHexesNearest(
        tap,
        [hexA],
        project,
        radius: kHexTapRadiusTouch,
      ),
      'A',
    );
    expect(
      hitTestCoverageBatchHexesNearest(
        tap,
        [hexA],
        project,
        radius: kHexTapRadiusMouse,
      ),
      isNull,
    );
  });

  test('zoom 16: tap inside a hex is unchanged', () {
    final camera = _camera(mapCenter, 16);
    Offset project(LatLng p) => coverageHexLayerOffset(camera, p);
    final tap = project(hexA.center) + const Offset(4, 0);
    expect(hitTestCoverageBatchHexesOnScreen(tap, [hexA], project), 'A');
    expect(
      hitTestCoverageBatchHexesNearest(
        tap,
        [hexA],
        project,
        radius: kHexTapRadiusTouch,
      ),
      'A',
    );
  });

  test('omitted center falls back to the ring centroid', () {
    final zone = coverageZonesFromHexDetails([
      HexDetail(row: origin.row, col: origin.col, scanCount: 1, lastTs: 1),
    ]).single;
    final hex = CoverageBatchHex(
      points: zone.polygon,
      hitId: 'cell',
      fill: const Color(0x4433AA55),
      border: const Color(0xFF33AA55),
    );
    expect(hex.center.latitude, closeTo(zone.centerLat, 1e-5));
    expect(hex.center.longitude, closeTo(zone.centerLng, 1e-5));
  });
}
