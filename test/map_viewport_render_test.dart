import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/map_viewport_render.dart';

CoverageZone _zone({
  required String id,
  required double lat,
  required double lng,
  List<LatLng>? polygon,
  bool isDeadZone = false,
  double? avgRssi = -80,
  double? avgSnr = 5,
  int scanCount = 1,
  DateTime? lastScanned,
}) {
  return CoverageZone(
    id: id,
    centerLat: lat,
    centerLng: lng,
    radiusMeters: 100,
    avgRssi: avgRssi,
    avgSnr: avgSnr,
    scanCount: scanCount,
    lastScanned: lastScanned ?? DateTime.utc(2024, 1, 1),
    isDeadZone: isDeadZone,
    polygon:
        polygon ??
        <LatLng>[
          LatLng(lat - 0.01, lng - 0.01),
          LatLng(lat - 0.01, lng + 0.01),
          LatLng(lat + 0.01, lng),
        ],
  );
}

MapRenderViewport _box({
  required double south,
  required double north,
  required double west,
  required double east,
  required double zoom,
  bool crossesAntimeridian = false,
  bool spansAllLongitudes = false,
}) {
  final width = spansAllLongitudes
      ? 360.0
      : crossesAntimeridian
      ? (180 - west) + (east + 180)
      : (east - west).abs();
  final center = spansAllLongitudes
      ? 0.0
      : crossesAntimeridian
      ? west + width / 2
      : (west + east) / 2;
  return MapRenderViewport.exact(
    south: south,
    north: north,
    west: west,
    east: east,
    crossesAntimeridian: crossesAntimeridian,
    spansAllLongitudes: spansAllLongitudes,
    zoom: zoom,
    longitudeCenter: center > 180 ? center - 360 : center,
    longitudeWidth: width,
  );
}

void main() {
  group('mapViewportRefreshDelay', () {
    test('debounces the start of a pan', () {
      expect(
        mapViewportRefreshDelay(sinceBurst: Duration.zero),
        mapViewportDebounce,
      );
    });

    test('shortens the wait so a long pan still refreshes', () {
      expect(
        mapViewportRefreshDelay(sinceBurst: const Duration(milliseconds: 180)),
        const Duration(milliseconds: 40),
      );
      expect(
        mapViewportRefreshDelay(sinceBurst: mapViewportMaxWait),
        Duration.zero,
      );
    });
  });

  group('viewport culling', () {
    test('keeps zones in view and drops zones outside it', () {
      final inside = _zone(id: 'in', lat: 37.5, lng: -122.2);
      final outside = _zone(id: 'out', lat: 40.0, lng: -74.0);
      final viewport = _box(
        south: 37.0,
        north: 38.0,
        west: -123.0,
        east: -122.0,
        zoom: 16,
      );

      final drawn = selectZonesForMapRender(
        zones: <CoverageZone>[inside, outside],
        viewport: viewport,
      );

      expect(drawn.map((polygon) => polygon.hitZoneId), <String>['in']);
      expect(drawn.single.isDeadZone, isFalse);
      expect(drawn.single.points, inside.polygon);
    });

    test('keeps a hex whose box covers a viewport that misses its center', () {
      final zone = _zone(
        id: 'cover',
        lat: 10,
        lng: 10,
        polygon: const <LatLng>[
          LatLng(9, 9),
          LatLng(9, 11),
          LatLng(11, 11),
          LatLng(11, 9),
        ],
      );
      final viewport = _box(
        south: 10.2,
        north: 10.25,
        west: 10.2,
        east: 10.25,
        zoom: 16,
      );

      final drawn = selectZonesForMapRender(
        zones: <CoverageZone>[zone],
        viewport: viewport,
      );

      expect(drawn.single.hitZoneId, 'cover');
    });

    test('margin keeps a nearby zone and still drops a far one', () {
      final near = _zone(id: 'near', lat: 12.2, lng: 0);
      final far = _zone(id: 'far', lat: 14, lng: 0);
      final viewport = MapRenderViewport.fromCenterWidth(
        south: 10,
        north: 12,
        longitudeCenter: 0,
        longitudeWidth: 2,
        zoom: 16,
      );

      expect(viewport.containsLatLng(12.2, 0), isTrue);
      expect(viewport.containsLatLng(14, 0), isFalse);

      final drawn = selectZonesForMapRender(
        zones: <CoverageZone>[near, far],
        viewport: viewport,
      );

      expect(drawn.map((polygon) => polygon.hitZoneId), <String>['near']);
    });

    test(
      'antimeridian window keeps both sides and drops the other hemisphere',
      () {
        final eastSide = _zone(id: 'east', lat: 0, lng: 179.2);
        final westSide = _zone(id: 'west', lat: 0, lng: -179.2);
        final remote = _zone(id: 'remote', lat: 0, lng: 0);
        final viewport = _box(
          south: -5,
          north: 5,
          west: 176,
          east: -176,
          zoom: 16,
          crossesAntimeridian: true,
        );

        expect(viewport.containsLatLng(0, 179.2), isTrue);
        expect(viewport.containsLatLng(0, -179.2), isTrue);
        expect(viewport.containsLatLng(0, 0), isFalse);

        final drawn = selectZonesForMapRender(
          zones: <CoverageZone>[eastSide, westSide, remote],
          viewport: viewport,
        );

        expect(drawn.map((polygon) => polygon.hitZoneId).toSet(), <String>{
          'east',
          'west',
        });
      },
    );

    test('ring that crosses ±180 still counts as inside a wrapped view', () {
      final crossing = _zone(
        id: 'cross',
        lat: 0.005,
        lng: 179.995,
        polygon: const <LatLng>[
          LatLng(0, 179.99),
          LatLng(0.01, 179.99),
          LatLng(0.01, -179.99),
          LatLng(0, -179.99),
        ],
      );
      final pacific = _zone(id: 'pacific', lat: 0, lng: 0);
      final viewport = _box(
        south: -1,
        north: 1,
        west: 179.5,
        east: -179.5,
        zoom: 16,
        crossesAntimeridian: true,
      );

      final drawn = selectZonesForMapRender(
        zones: <CoverageZone>[crossing, pacific],
        viewport: viewport,
      );

      expect(drawn.map((polygon) => polygon.hitZoneId), <String>['cross']);
    });

    test('fromCenterWidth marks a date-line camera as wrapped', () {
      final viewport = MapRenderViewport.fromCenterWidth(
        south: -1,
        north: 1,
        longitudeCenter: 179.5,
        longitudeWidth: 3,
        zoom: 16,
      );

      expect(viewport.crossesAntimeridian, isTrue);
      expect(viewport.containsLatLng(0, 179.6), isTrue);
      expect(viewport.containsLatLng(0, -179.6), isTrue);
      expect(viewport.containsLatLng(0, 0), isFalse);

      final otherSide = MapRenderViewport.fromCenterWidth(
        south: -1,
        north: 1,
        longitudeCenter: -179.5,
        longitudeWidth: 3,
        zoom: 16,
      );
      expect(otherSide.crossesAntimeridian, isTrue);
      expect(otherSide.containsLatLng(0, -179.6), isTrue);
      expect(otherSide.containsLatLng(0, 179.6), isTrue);
      expect(otherSide.containsLatLng(0, 0), isFalse);
    });

    test('does not draw zones absent from the selected dataset', () {
      final kept = _zone(id: 'kept', lat: 1, lng: 1);
      final hidden = _zone(id: 'hidden', lat: 1.1, lng: 1.1);
      final viewport = _box(south: 0, north: 2, west: 0, east: 2, zoom: 16);

      final drawn = selectZonesForMapRender(
        zones: <CoverageZone>[kept],
        viewport: viewport,
      );

      expect(drawn.single.hitZoneId, 'kept');
      expect(hidden.id, 'hidden');
    });

    test('preserves a dead zone at detail zoom', () {
      final dead = _zone(
        id: 'dead',
        lat: 5,
        lng: 5,
        isDeadZone: true,
        avgRssi: null,
        avgSnr: null,
      );
      final viewport = _box(south: 0, north: 10, west: 0, east: 10, zoom: 16);

      final drawn = selectZonesForMapRender(
        zones: <CoverageZone>[dead],
        viewport: viewport,
      );

      expect(drawn.single.isDeadZone, isTrue);
      expect(drawn.single.avgRssi, isNull);
    });
  });

  group('low zoom bound', () {
    test(
      'stops at the max hex scale instead of growing to hold every zone',
      () {
        final zones = List<CoverageZone>.generate(9021, (index) {
          final lat = -70.0 + (index % 140);
          final lng = -180.0 + ((index * 7) % 360);
          return _zone(
            id: 'z$index',
            lat: lat,
            lng: lng,
            polygon: const <LatLng>[],
            isDeadZone: index.isEven,
            scanCount: index + 1,
          );
        });
        final viewport = _box(
          south: -85,
          north: 85,
          west: -180,
          east: 180,
          zoom: 3,
          spansAllLongitudes: true,
        );

        final plan = planZonesForMapRender(zones: zones, viewport: viewport);

        expect(zones, hasLength(9021));
        expect(plan.nominalScale, mapHexMaxScale);
        expect(plan.scale, mapHexMaxScale);
        expect(plan.polygons, hasLength(mapMaxDrawnPolygons));
        expect(plan.usedEmergencyBackstop, isTrue);
        expect(plan.droppedChildren, isTrue);
        expect(plan.representedChildren, lessThan(9021));
        expect(plan.representedChildren, greaterThan(0));
        final ids = zones.map((zone) => zone.id).toSet();
        final represented = <String>{};
        for (final polygon in plan.polygons) {
          expect(polygon.points, hasLength(6));
          expect(polygon.scale, mapHexMaxScale);
          expect(ids, contains(polygon.hitZoneId));
          represented.addAll(polygon.memberZoneIds);
          for (var i = 0; i < polygon.points.length; i++) {
            final next = polygon.points[(i + 1) % polygon.points.length];
            expect(
              (polygon.points[i].longitude - next.longitude).abs(),
              lessThan(180),
            );
          }
        }
        expect(represented, isNot(ids));
        expect(represented.length, lessThan(ids.length));
      },
    );

    test('low zoom viewport does not paint a zone outside it', () {
      final inside = _zone(
        id: 'inside',
        lat: 37.5,
        lng: -122.5,
        polygon: const <LatLng>[],
      );
      final outside = _zone(
        id: 'outside',
        lat: 0,
        lng: 0,
        polygon: const <LatLng>[],
      );
      final viewport = _box(
        south: 37,
        north: 38,
        west: -123,
        east: -122,
        zoom: 4,
      );

      final drawn = selectZonesForMapRender(
        zones: <CoverageZone>[inside, outside],
        viewport: viewport,
      );

      expect(drawn.map((polygon) => polygon.hitZoneId), <String>['inside']);
      expect(<CoverageZone>[inside, outside], hasLength(2));
    });

    test('dead-only cells stay dead and mixed cells keep a heard zone', () {
      final dead = _zone(
        id: 'dead',
        lat: 10,
        lng: 10,
        isDeadZone: true,
        avgRssi: null,
        avgSnr: null,
        scanCount: 9,
        polygon: const <LatLng>[],
      );
      final heard = _zone(
        id: 'heard',
        lat: 10,
        lng: 10,
        avgRssi: -70,
        avgSnr: 4,
        scanCount: 2,
        polygon: const <LatLng>[],
      );
      final viewport = _box(south: 9, north: 11, west: 9, east: 11, zoom: 3);

      final drawn = selectZonesForMapRender(
        zones: <CoverageZone>[dead, heard],
        viewport: viewport,
      );

      expect(drawn, hasLength(1));
      expect(drawn.single.isDeadZone, isFalse);
      expect(drawn.single.hitZoneId, 'heard');
      expect(drawn.single.avgRssi, closeTo(-70, 0.001));
    });

    test('aggregate edges stay on one side of the date line', () {
      final eastSide = _zone(
        id: 'east',
        lat: 0,
        lng: 179,
        polygon: const <LatLng>[],
      );
      final westSide = _zone(
        id: 'west',
        lat: 0,
        lng: -179,
        polygon: const <LatLng>[],
      );
      final remote = _zone(
        id: 'remote',
        lat: 0,
        lng: 0,
        polygon: const <LatLng>[],
      );
      final viewport = _box(
        south: -5,
        north: 5,
        west: 176,
        east: -176,
        zoom: 3,
        crossesAntimeridian: true,
      );

      final drawn = selectZonesForMapRender(
        zones: <CoverageZone>[eastSide, westSide, remote],
        viewport: viewport,
      );

      expect(drawn.map((polygon) => polygon.hitZoneId).toSet(), <String>{
        'east',
        'west',
      });
      for (final polygon in drawn) {
        for (var i = 0; i < polygon.points.length; i++) {
          final next = polygon.points[(i + 1) % polygon.points.length];
          expect(
            (polygon.points[i].longitude - next.longitude).abs(),
            lessThan(180),
          );
        }
      }
    });
  });

  group('detail zoom cap', () {
    test('draws every in-view hex when the count is under the cap', () {
      final zones = <CoverageZone>[
        _zone(id: 'a', lat: 1, lng: 1),
        _zone(id: 'b', lat: 1.2, lng: 1.2),
        _zone(id: 'c', lat: 1.4, lng: 1.1),
        _zone(id: 'far', lat: 40, lng: 40),
      ];
      final viewport = _box(south: 0, north: 3, west: 0, east: 3, zoom: 16);

      final drawn = selectZonesForMapRender(zones: zones, viewport: viewport);

      expect(drawn.map((polygon) => polygon.hitZoneId).toSet(), <String>{
        'a',
        'b',
        'c',
      });
      expect(drawn.every((polygon) => polygon.points.length == 3), isTrue);
    });

    test('coarsens a dense exact-zoom view instead of dropping cells', () {
      final zones = List<CoverageZone>.generate(2000, (index) {
        final lat = (index % 40) * 0.12;
        final lng = (index ~/ 40) * 0.2;
        return _zone(id: 'd$index', lat: lat, lng: lng);
      });
      final viewport = _box(south: -1, north: 6, west: -1, east: 12, zoom: 16);

      final plan = planZonesForMapRender(zones: zones, viewport: viewport);

      expect(plan.nominalScale, 1);
      expect(plan.scale, lessThanOrEqualTo(mapHexMaxScale));
      expect(plan.scale, greaterThan(plan.nominalScale));
      expect(plan.usedEmergencyBackstop, isTrue);
      expect(plan.droppedChildren, isFalse);
      expect(plan.polygons.length, lessThanOrEqualTo(mapMaxDrawnPolygons));
      expect(plan.polygons.length, greaterThan(1));
      expect(plan.representedChildren, zones.length);
      expect(
        plan.polygons.every((polygon) => polygon.points.length == 6),
        isTrue,
      );
      final ids = <String>{
        for (final polygon in plan.polygons) ...polygon.memberZoneIds,
      };
      expect(ids, zones.map((zone) => zone.id).toSet());
    });

    test(
      'keeps a selected cell inside its cluster when the view is coarsened',
      () {
        final zones = List<CoverageZone>.generate(2000, (index) {
          final lat = (index % 40) * 0.12;
          final lng = (index ~/ 40) * 0.2;
          return _zone(id: 'd$index', lat: lat, lng: lng, scanCount: 1);
        });
        final viewport = _box(
          south: -1,
          north: 6,
          west: -1,
          east: 12,
          zoom: 16,
        );

        final drawn = selectZonesForMapRender(
          zones: zones,
          viewport: viewport,
          pinZoneId: 'd10',
        );

        expect(drawn.length, lessThanOrEqualTo(mapMaxDrawnPolygons));
        expect(drawn.any((polygon) => polygon.containsZone('d10')), isTrue);
      },
    );
  });
}
