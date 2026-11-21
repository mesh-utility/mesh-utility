import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/hex_tap_target.dart';

CoverageZone _zone(String id, double lat, double lng) {
  return CoverageZone(
    id: id,
    centerLat: lat,
    centerLng: lng,
    radiusMeters: 100,
    avgRssi: -80,
    avgSnr: 5,
    scanCount: 1,
    lastScanned: DateTime.utc(2026, 1, 1),
    isDeadZone: false,
    polygon: const <LatLng>[],
  );
}

void main() {
  test('coverageHexCentres keeps order and skips non-finite centres', () {
    final centres = coverageHexCentres(<CoverageZone>[
      _zone('a', 1, 2),
      _zone('bad', double.nan, 0),
      _zone('b', 3, 4),
      _zone('also-bad', 1, double.infinity),
    ]);
    expect(centres.map((centre) => centre.id), <String>['a', 'b']);
    expect(centres.first.latitude, 1);
    expect(centres.last.longitude, 4);
  });

  test('nearest centre hits inside the radius and misses outside it', () {
    final centres = <CoverageHexCentre>[
      const CoverageHexCentre(id: 'near', latitude: 0, longitude: 0),
    ];
    Offset project(LatLng point) => Offset(point.longitude, point.latitude);
    bool inView(double lat, double lng) => true;

    expect(
      nearestCoverageHexCentre(
        layerPoint: const Offset(8, 0),
        centres: centres,
        inView: inView,
        project: project,
        radius: 10,
      ),
      'near',
    );
    expect(
      nearestCoverageHexCentre(
        layerPoint: const Offset(10, 0),
        centres: centres,
        inView: inView,
        project: project,
        radius: 10,
      ),
      'near',
    );
    expect(
      nearestCoverageHexCentre(
        layerPoint: const Offset(10.1, 0),
        centres: centres,
        inView: inView,
        project: project,
        radius: 10,
      ),
      isNull,
    );
  });

  test('nearer in-view centre wins without requiring sorted input', () {
    final centres = <CoverageHexCentre>[
      const CoverageHexCentre(id: 'far', latitude: 0, longitude: 30),
      const CoverageHexCentre(id: 'near', latitude: 0, longitude: 4),
    ];
    Offset project(LatLng point) => Offset(point.longitude, point.latitude);

    expect(
      nearestCoverageHexCentre(
        layerPoint: Offset.zero,
        centres: centres,
        inView: (lat, lng) => true,
        project: project,
        radius: 24,
      ),
      'near',
    );
    expect(
      nearestCoverageHexCentre(
        layerPoint: const Offset(30, 0),
        centres: centres,
        inView: (lat, lng) => lng > 10,
        project: project,
        radius: 24,
      ),
      'far',
      reason: 'the nearer centre is outside the view',
    );
  });

  test('empty, non-finite, and negative radius miss', () {
    const centres = <CoverageHexCentre>[
      CoverageHexCentre(id: 'a', latitude: 0, longitude: 0),
    ];
    Offset project(LatLng point) => Offset(point.longitude, point.latitude);

    expect(
      nearestCoverageHexCentre(
        layerPoint: Offset.zero,
        centres: const <CoverageHexCentre>[],
        inView: (lat, lng) => true,
        project: project,
        radius: 24,
      ),
      isNull,
    );
    expect(
      nearestCoverageHexCentre(
        layerPoint: const Offset(double.nan, 0),
        centres: centres,
        inView: (lat, lng) => true,
        project: project,
        radius: 24,
      ),
      isNull,
    );
    expect(
      nearestCoverageHexCentre(
        layerPoint: Offset.zero,
        centres: centres,
        inView: (lat, lng) => true,
        project: project,
        radius: -1,
      ),
      isNull,
    );
  });
}
