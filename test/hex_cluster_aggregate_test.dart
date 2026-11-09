import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/map_viewport_render.dart';

CoverageZone _zone({
  required String id,
  required double lat,
  required double lng,
  bool isDeadZone = false,
  double? avgRssi = -80,
  double? avgSnr = 5,
  int scanCount = 1,
  DateTime? lastScanned,
  List<LatLng>? polygon,
}) {
  return CoverageZone(
    id: id,
    centerLat: lat,
    centerLng: lng,
    radiusMeters: 100,
    avgRssi: isDeadZone ? null : avgRssi,
    avgSnr: isDeadZone ? null : avgSnr,
    scanCount: scanCount,
    lastScanned: lastScanned ?? DateTime.utc(2024, 1, 1),
    isDeadZone: isDeadZone,
    polygon: polygon ?? hexVertices(lat, lng),
  );
}

MapRenderViewport _world(double zoom) {
  return MapRenderViewport.exact(
    south: -85,
    north: 85,
    west: -180,
    east: 180,
    crossesAntimeridian: false,
    spansAllLongitudes: true,
    zoom: zoom,
    longitudeCenter: 0,
    longitudeWidth: 360,
  );
}

MapRenderViewport _phone({
  required double zoom,
  required double lat,
  required double lng,
  double widthPx = 400,
  double heightPx = 800,
}) {
  final degreesPerPixel = 360 / (256 * math.pow(2, zoom));
  return MapRenderViewport.fromCenterWidth(
    south: lat - heightPx * degreesPerPixel / 2,
    north: lat + heightPx * degreesPerPixel / 2,
    longitudeCenter: lng,
    longitudeWidth: widthPx * degreesPerPixel,
    zoom: zoom,
  );
}

List<CoverageZone> _city({int rows = 95, int cols = 95}) {
  final zones = <CoverageZone>[];
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < cols; col++) {
      final center = hexCellCenter(row, col);
      zones.add(_zone(id: 'r$row:c$col', lat: center.lat, lng: center.lng));
    }
  }
  return zones;
}

void main() {
  group('zoom bands', () {
    test('exact cells start at 15.5 and each lower band doubles the hex', () {
      expect(mapDetailZoom, 15.5);
      expect(mapHexMaxScale, 256);
      expect(mapHexMaxScaleZoom, 7.5);
      expect(hexClusterScaleForZoom(15.5), 1);
      expect(hexClusterScaleForZoom(18), 1);
      expect(hexClusterScaleForZoom(15.49), 2);
      expect(hexClusterScaleForZoom(14.5), 2);
      expect(hexClusterScaleForZoom(14.49), 4);
      expect(hexClusterScaleForZoom(13.5), 4);
      expect(hexClusterScaleForZoom(12.5), 8);
      expect(hexClusterScaleForZoom(11.5), 16);
      expect(hexClusterScaleForZoom(10.5), 32);
      expect(hexClusterScaleForZoom(9.5), 64);
      expect(hexClusterScaleForZoom(8.5), 128);
      expect(hexClusterScaleForZoom(8.49), mapHexMaxScale);
      expect(hexClusterScaleForZoom(mapHexMaxScaleZoom), mapHexMaxScale);
      expect(hexClusterScaleForZoom(mapHexMaxScaleZoom - 0.01), mapHexMaxScale);
      expect(hexClusterScaleForZoom(6.5), mapHexMaxScale);
      expect(hexClusterScaleForZoom(3), mapHexMaxScale);
      expect(hexClusterScaleForZoom(0.5), mapHexMaxScale);
      expect(hexClusterScaleForZoom(0), mapHexMaxScale);
      expect(hexClusterScaleForZoom(-2), mapHexMaxScale);
      expect(hexClusterScaleForZoom(double.nan), mapHexMaxScale);
      expect(coarserHexScale(1), 2);
      expect(coarserHexScale(128), mapHexMaxScale);
      expect(coarserHexScale(mapHexMaxScale), isNull);
      expect(coarserHexScale(512), isNull);
      expect(coarserHexScale(65536), isNull);
      expect(
        mapHexZoomBands.map((band) => band.scale),
        everyElement(lessThanOrEqualTo(mapHexMaxScale)),
      );
    });

    test('scale 256 is the central Pennsylvania width stop', () {
      const lat = 40.7;
      const lng = -77.7;
      final widthMiles = distanceMiles(
        lat,
        lng,
        lat,
        lng + colSpacing * mapHexMaxScale,
      );
      final smallerMiles = distanceMiles(
        lat,
        lng,
        lat,
        lng + colSpacing * (mapHexMaxScale >> 1),
      );
      final largerMiles = distanceMiles(
        lat,
        lng,
        lat,
        lng + colSpacing * (mapHexMaxScale << 1),
      );
      // Flat-to-flat column spacing at State College / Lewistown latitude.
      expect(widthMiles, closeTo(19.51, 0.05));
      expect(widthMiles * 1.609344, closeTo(31.40, 0.1));
      expect(smallerMiles, lessThan(15));
      expect(largerMiles, greaterThan(20));
    });

    test('mile labels and the user-max steps share the band list', () {
      expect(mapHexScaleSteps, <int>[1, 2, 4, 8, 16, 32, 64, 128, 256]);
      expect(
        mapHexZoomBands.map((band) => band.scale).toList(),
        mapHexScaleSteps,
      );
      expect(hexScaleMilesLabel(1), 'Actual cells (~0.08 mi)');
      expect(hexScaleMilesLabel(2), '~0.15 mi');
      expect(hexScaleMilesLabel(4), '~0.3 mi');
      expect(hexScaleMilesLabel(8), '~0.6 mi');
      expect(hexScaleMilesLabel(16), '~1.2 mi');
      expect(hexScaleMilesLabel(32), '~2.4 mi');
      expect(hexScaleMilesLabel(64), '~4.9 mi');
      expect(hexScaleMilesLabel(128), '~9.8 mi');
      expect(hexScaleMilesLabel(mapHexMaxScale), '~19.5 mi');
      expect(clampMaxHexScale(null), mapHexMaxScale);
      expect(clampMaxHexScale(0), 1);
      expect(clampMaxHexScale(3), 4);
      expect(clampMaxHexScale(7), 8);
      expect(clampMaxHexScale(1000), mapHexMaxScale);
      expect(hexClusterScaleForZoom(5, maxScale: 8), 8);
      expect(hexClusterScaleForZoom(5, maxScale: 1), 1);
      expect(hexClusterScaleForZoom(16, maxScale: 8), 1);
      expect(hexClusterScaleForZoom(12, maxScale: 8), 8);
      expect(hexClusterScaleForZoom(14, maxScale: 8), 4);
      expect(coarserHexScale(4, maxScale: 8), 8);
      expect(coarserHexScale(8, maxScale: 8), isNull);
      expect(coarserHexScale(1, maxScale: 1), isNull);
    });
  });

  group('aggregation', () {
    test('parent hex contains its fine cells and not the next parent', () {
      const scale = 8;
      final parent = hexCellAt(37.5, -122.25, scale: scale);
      // Place children by snapping offsets that stay inside this parent.
      final childA = _zone(id: 'a', lat: parent.lat, lng: parent.lng);
      final childB = _zone(
        id: 'b',
        lat: parent.lat + rowSpacing,
        lng: parent.lng,
      );
      final childParent = hexCellAt(
        childB.centerLat,
        childB.centerLng,
        scale: scale,
      );
      expect(childParent.row, parent.row);
      expect(childParent.col, parent.col);

      final elsewhere = hexCellCenter(parent.row + 1, parent.col, scale: scale);
      final outside = _zone(id: 'out', lat: elsewhere.lat, lng: elsewhere.lng);
      expect(
        hexCellAt(outside.centerLat, outside.centerLng, scale: scale).row,
        isNot(parent.row),
      );

      final clusters = aggregateCoverageHexes(<CoverageZone>[
        childA,
        outside,
        childB,
      ], scale: scale);

      expect(clusters, hasLength(2));
      final home = clusters.firstWhere((cluster) => cluster.row == parent.row);
      expect(home.memberZoneIds, <String>['a', 'b']);
      expect(home.childCount, 2);
      expect(home.points, hasLength(6));
      expect(home.centerLat, closeTo(parent.lat, 1e-9));
      expect(home.centerLng, closeTo(parent.lng, 1e-9));
      expect(home.scale, scale);
      expect(
        clusters.map((cluster) => cluster.memberZoneIds).expand((ids) => ids),
        <String>['a', 'b', 'out'],
      );
      // Scale 1 keeps the stored ring.
      final exact = aggregateCoverageHexes(<CoverageZone>[childA], scale: 1);
      expect(exact.single.points, childA.polygon);
    });

    test('best heard state wins over a busier dead cell', () {
      final dead = _zone(
        id: 'dead',
        lat: 10,
        lng: 10,
        isDeadZone: true,
        scanCount: 40,
      );
      final poor = _zone(
        id: 'poor',
        lat: 10,
        lng: 10,
        avgRssi: -120,
        avgSnr: -20,
        scanCount: 9,
      );
      final excellent = _zone(
        id: 'excellent',
        lat: 10,
        lng: 10,
        avgRssi: -80,
        avgSnr: 12,
        scanCount: 1,
      );
      final clusters = aggregateCoverageHexes(<CoverageZone>[
        dead,
        poor,
        excellent,
      ], scale: 64);

      expect(clusters, hasLength(1));
      final cluster = clusters.single;
      expect(cluster.isDeadZone, isFalse);
      expect(cluster.hitZoneId, 'excellent');
      expect(cluster.avgRssi, closeTo(-80, 0.001));
      expect(cluster.avgSnr, closeTo(12, 0.001));
      expect(cluster.childCount, 3);
      expect(cluster.coveredCount, 2);
      expect(
        formatCoverageFraction(
          heard: cluster.coveredCount,
          filteredChildren: cluster.childCount,
        ),
        '2/3 heard (67%)',
      );
    });

    test(
      'noisy beats a weaker poor cell and a dead-only cluster stays dead',
      () {
        final noisy = _zone(
          id: 'noisy',
          lat: 1,
          lng: 1,
          avgRssi: -95,
          avgSnr: -14,
        );
        final poor = _zone(
          id: 'poor',
          lat: 1,
          lng: 1,
          avgRssi: -120,
          avgSnr: -20,
        );
        final mixed = aggregateCoverageHexes(<CoverageZone>[
          poor,
          noisy,
        ], scale: 32);
        expect(mixed.single.hitZoneId, 'noisy');
        expect(mixed.single.avgRssi, closeTo(-95, 0.001));
        expect(mixed.single.coveredCount, 2);

        final deadA = _zone(
          id: 'd1',
          lat: 2,
          lng: 2,
          isDeadZone: true,
          scanCount: 3,
        );
        final deadB = _zone(
          id: 'd0',
          lat: 2,
          lng: 2,
          isDeadZone: true,
          scanCount: 1,
        );
        final dead = aggregateCoverageHexes(<CoverageZone>[
          deadA,
          deadB,
        ], scale: 32);
        expect(dead.single.isDeadZone, isTrue);
        expect(dead.single.coveredCount, 0);
        expect(dead.single.avgRssi, isNull);
        expect(dead.single.childCount, 2);
        expect(
          formatCoverageFraction(heard: 0, filteredChildren: 2),
          '0/2 heard (0%)',
        );
        expect(coverageFractionMeaning, contains('filtered cells'));
        expect(coverageFractionMeaning, contains('Unscanned'));
      },
    );

    test('aggregation sees only the filtered list', () {
      final heard = _zone(id: 'heard', lat: 4, lng: 4, avgRssi: -70, avgSnr: 6);
      final dead = _zone(
        id: 'dead',
        lat: 4,
        lng: 4,
        isDeadZone: true,
        scanCount: 20,
      );
      final viewport = _world(8);
      final all = planZonesForMapRender(
        zones: <CoverageZone>[dead, heard],
        viewport: viewport,
      );
      final filtered = planZonesForMapRender(
        zones: <CoverageZone>[dead],
        viewport: viewport,
      );

      expect(all.polygons.single.isDeadZone, isFalse);
      expect(all.polygons.single.hitZoneId, 'heard');
      expect(all.representedChildren, 2);
      expect(filtered.polygons.single.isDeadZone, isTrue);
      expect(filtered.polygons.single.childCount, 1);
      expect(filtered.polygons.single.memberZoneIds, <String>['dead']);
    });
  });

  group('low zoom coverage', () {
    test('a city of fine cells is fully represented without the backstop', () {
      final zones = _city();
      final center = hexCellCenter(47, 47);
      for (final zoom in <double>[8, 12, 14, 16]) {
        final viewport = _phone(zoom: zoom, lat: center.lat, lng: center.lng);
        final plan = planZonesForMapRender(zones: zones, viewport: viewport);
        expect(plan.usedEmergencyBackstop, isFalse, reason: 'zoom $zoom');
        expect(plan.droppedChildren, isFalse, reason: 'zoom $zoom');
        expect(plan.polygons.length, lessThanOrEqualTo(mapMaxDrawnPolygons));
        expect(plan.scale, hexClusterScaleForZoom(zoom), reason: 'zoom $zoom');
        final represented = <String>{
          for (final polygon in plan.polygons) ...polygon.memberZoneIds,
        };
        for (final zone in zones) {
          if (viewport.containsLatLng(zone.centerLat, zone.centerLng)) {
            expect(
              represented,
              contains(zone.id),
              reason: 'zoom $zoom ${zone.id}',
            );
          }
        }
        if (zoom < mapDetailZoom) {
          expect(
            plan.polygons.every((polygon) => polygon.points.length == 6),
            isTrue,
          );
        }
      }
    });

    test('world view of the same city keeps every filtered cell', () {
      final zones = _city();
      final plan = planZonesForMapRender(zones: zones, viewport: _world(3));
      expect(plan.nominalScale, mapHexMaxScale);
      expect(plan.scale, mapHexMaxScale);
      expect(plan.usedEmergencyBackstop, isFalse);
      expect(plan.droppedChildren, isFalse);
      expect(plan.representedChildren, zones.length);
      expect(plan.polygons.length, lessThan(20));
      final ids = plan.polygons
          .expand((polygon) => polygon.memberZoneIds)
          .toSet();
      expect(ids, zones.map((zone) => zone.id).toSet());
    });

    test('zoom below the cutoff does not change hex geometry', () {
      final zones = _city(rows: 6, cols: 6);
      final atBand = planZonesForMapRender(
        zones: zones,
        viewport: _world(mapHexMaxScaleZoom),
      );
      final below = planZonesForMapRender(
        zones: zones,
        viewport: _world(mapHexMaxScaleZoom - 0.01),
      );
      final extreme = planZonesForMapRender(zones: zones, viewport: _world(0));
      final negative = planZonesForMapRender(
        zones: zones,
        viewport: _world(-2),
      );
      for (final plan in <MapRenderPlan>[atBand, below, extreme, negative]) {
        expect(plan.scale, mapHexMaxScale);
        expect(plan.nominalScale, mapHexMaxScale);
        expect(plan.droppedChildren, isFalse);
        expect(plan.usedEmergencyBackstop, isFalse);
        expect(plan.representedChildren, zones.length);
        expect(plan.polygons, hasLength(1));
        expect(plan.polygons.single.scale, mapHexMaxScale);
      }
      expect(below.polygons.single.points, atBand.polygons.single.points);
      expect(extreme.polygons.single.points, atBand.polygons.single.points);
      expect(negative.polygons.single.points, atBand.polygons.single.points);
    });
  });

  group('emergency backstop', () {
    List<CoverageZone> parentGrid({
      required int rowMin,
      required int rowMax,
      required int colMin,
      required int colMax,
    }) {
      final zones = <CoverageZone>[];
      for (var row = rowMin; row <= rowMax; row++) {
        for (var col = colMin; col <= colMax; col++) {
          final center = hexCellCenter(row, col, scale: mapHexMaxScale);
          zones.add(_zone(id: 'r$row:c$col', lat: center.lat, lng: center.lng));
        }
      }
      return zones;
    }

    test(
      'keeps the central parents when the capped scale is still overfull',
      () {
        final zones = <CoverageZone>[
          for (var row = -3; row <= 3; row++)
            _zone(
              id: 'r$row',
              lat: hexCellCenter(row, 0, scale: mapHexMaxScale).lat,
              lng: hexCellCenter(row, 0, scale: mapHexMaxScale).lng,
            ),
        ];
        final plan = planZonesForMapRender(
          zones: zones,
          viewport: _world(0),
          maxDrawn: 3,
        );

        expect(plan.nominalScale, mapHexMaxScale);
        expect(plan.scale, mapHexMaxScale);
        expect(plan.usedEmergencyBackstop, isTrue);
        expect(plan.droppedChildren, isTrue);
        expect(plan.polygons, hasLength(3));
        expect(
          plan.polygons.map((polygon) => polygon.hitZoneId).toSet(),
          <String>{'r-1', 'r0', 'r1'},
        );
        expect(
          plan.polygons.every((polygon) => polygon.scale == mapHexMaxScale),
          isTrue,
        );

        final pinned = planZonesForMapRender(
          zones: zones,
          viewport: _world(0),
          maxDrawn: 3,
          pinZoneId: 'r3',
        );
        expect(pinned.polygons, hasLength(3));
        expect(pinned.scale, mapHexMaxScale);
        expect(
          pinned.polygons.any((polygon) => polygon.containsZone('r3')),
          isTrue,
        );
        expect(
          pinned.polygons.any((polygon) => polygon.containsZone('r0')),
          isTrue,
        );
      },
    );

    test(
      '700 backstop stops at the max scale and prefers the viewport center',
      () async {
        final scales = <int>[];
        final session = HexRenderSession(
          aggregate: (zones, scale) async {
            scales.add(scale);
            return aggregateCoverageHexes(zones, scale: scale);
          },
        );
        final zones = parentGrid(
          rowMin: -20,
          rowMax: 20,
          colMin: -10,
          colMax: 10,
        );
        expect(zones.length, greaterThan(mapMaxDrawnPolygons));
        final plan = await session.render(
          identity: 1,
          zones: zones,
          viewport: _world(16),
        );

        expect(scales, <int>[1, 2, 4, 8, 16, 32, 64, 128, mapHexMaxScale]);
        expect(plan, isNotNull);
        expect(plan!.nominalScale, 1);
        expect(plan.scale, mapHexMaxScale);
        expect(plan.usedEmergencyBackstop, isTrue);
        expect(plan.droppedChildren, isTrue);
        expect(plan.polygons, hasLength(mapMaxDrawnPolygons));
        expect(plan.representedChildren, lessThan(zones.length));
        expect(
          plan.polygons.every((polygon) => polygon.scale == mapHexMaxScale),
          isTrue,
        );
        final kept = plan.polygons
            .expand((polygon) => polygon.memberZoneIds)
            .toSet();
        expect(kept, contains('r0:c0'));
        expect(kept, isNot(contains('r20:c10')));
        expect(kept, isNot(contains('r-20:c-10')));
      },
    );

    test('culling still drops parents outside the viewport at the cap', () {
      final zones = parentGrid(
        rowMin: -25,
        rowMax: 25,
        colMin: -15,
        colMax: 15,
      );
      final farNorth = hexCellCenter(200, 0, scale: mapHexMaxScale);
      final farEast = hexCellCenter(0, 80, scale: mapHexMaxScale);
      zones.add(_zone(id: 'far-north', lat: farNorth.lat, lng: farNorth.lng));
      zones.add(_zone(id: 'far-east', lat: farEast.lat, lng: farEast.lng));
      final center = hexCellCenter(0, 0, scale: mapHexMaxScale);
      final viewport = _phone(zoom: 6, lat: center.lat, lng: center.lng);
      final plan = planZonesForMapRender(zones: zones, viewport: viewport);

      expect(plan.scale, mapHexMaxScale);
      expect(plan.polygons.length, lessThanOrEqualTo(mapMaxDrawnPolygons));
      final ids = plan.polygons
          .expand((polygon) => polygon.memberZoneIds)
          .toSet();
      expect(ids, contains('r0:c0'));
      expect(ids, isNot(contains('far-north')));
      expect(ids, isNot(contains('far-east')));
      expect(viewport.containsLatLng(farNorth.lat, farNorth.lng), isFalse);
      expect(viewport.containsLatLng(farEast.lat, farEast.lng), isFalse);
    });

    test(
      'a user max of 1 stays on actual cells and drops by viewport priority',
      () async {
        final scales = <int>[];
        final session = HexRenderSession(
          aggregate: (zones, scale) async {
            scales.add(scale);
            return aggregateCoverageHexes(zones, scale: scale);
          },
        );
        final zones = parentGrid(
          rowMin: -20,
          rowMax: 20,
          colMin: -10,
          colMax: 10,
        );
        expect(zones.length, greaterThan(mapMaxDrawnPolygons));
        final plan = await session.render(
          identity: 1,
          zones: zones,
          viewport: _world(5),
          maxScale: 1,
        );

        expect(scales, <int>[1]);
        expect(plan, isNotNull);
        expect(plan!.nominalScale, 1);
        expect(plan.scale, 1);
        expect(plan.usedEmergencyBackstop, isTrue);
        expect(plan.droppedChildren, isTrue);
        expect(plan.polygons, hasLength(mapMaxDrawnPolygons));
        expect(plan.polygons.every((polygon) => polygon.scale == 1), isTrue);
        final kept = plan.polygons
            .expand((polygon) => polygon.memberZoneIds)
            .toSet();
        expect(kept, contains('r0:c0'));
        expect(kept, isNot(contains('r20:c10')));
        expect(kept, isNot(contains('r-20:c-10')));
      },
    );
  });

  group('user max hex scale', () {
    test('zoom 5 with max scale 8 does not draw the regional parent', () {
      final zones = _city(rows: 12, cols: 12);
      final capped = planZonesForMapRender(
        zones: zones,
        viewport: _world(5),
        maxScale: 8,
      );
      final hard = planZonesForMapRender(zones: zones, viewport: _world(5));

      expect(hexClusterScaleForZoom(5), mapHexMaxScale);
      expect(capped.nominalScale, 8);
      expect(capped.scale, 8);
      expect(capped.scale, lessThan(hard.scale));
      expect(hard.scale, mapHexMaxScale);
      expect(capped.usedEmergencyBackstop, isFalse);
      expect(capped.droppedChildren, isFalse);
      expect(capped.representedChildren, zones.length);
      expect(capped.polygons.every((polygon) => polygon.scale == 8), isTrue);
    });

    test('explicit default cap matches the hard ceiling', () {
      final zones = _city(rows: 6, cols: 6);
      final implicit = planZonesForMapRender(zones: zones, viewport: _world(3));
      final explicit = planZonesForMapRender(
        zones: zones,
        viewport: _world(3),
        maxScale: mapHexMaxScale,
      );

      expect(explicit.nominalScale, implicit.nominalScale);
      expect(explicit.scale, mapHexMaxScale);
      expect(explicit.droppedChildren, isFalse);
      expect(explicit.representedChildren, zones.length);
      expect(explicit.polygons.single.points, implicit.polygons.single.points);
    });

    test('backstop coarsens only up to the user max', () async {
      final scales = <int>[];
      final session = HexRenderSession(
        aggregate: (zones, scale) async {
          scales.add(scale);
          return aggregateCoverageHexes(zones, scale: scale);
        },
      );
      final zones = <CoverageZone>[];
      for (var row = -20; row <= 20; row++) {
        for (var col = -10; col <= 10; col++) {
          final center = hexCellCenter(row, col, scale: mapHexMaxScale);
          zones.add(_zone(id: 'r$row:c$col', lat: center.lat, lng: center.lng));
        }
      }
      final plan = await session.render(
        identity: 1,
        zones: zones,
        viewport: _world(16),
        maxScale: 8,
      );

      expect(scales, <int>[1, 2, 4, 8]);
      expect(plan, isNotNull);
      expect(plan!.nominalScale, 1);
      expect(plan.scale, 8);
      expect(plan.droppedChildren, isTrue);
      expect(plan.polygons, hasLength(mapMaxDrawnPolygons));
      expect(plan.polygons.every((polygon) => polygon.scale == 8), isTrue);
    });
  });

  group('render cache', () {
    test(
      'pan in one band reuses the aggregate and a new filter does not',
      () async {
        var calls = 0;
        final session = HexRenderSession(
          aggregate: (zones, scale) async {
            calls++;
            return aggregateCoverageHexes(zones, scale: scale);
          },
        );
        final zones = _city(rows: 10, cols: 10);
        final origin = hexCellCenter(5, 5);
        final first = await session.render(
          identity: 1,
          zones: zones,
          viewport: _phone(zoom: 8, lat: origin.lat, lng: origin.lng),
        );
        final second = await session.render(
          identity: 1,
          zones: zones,
          viewport: _phone(zoom: 8.2, lat: origin.lat + 0.2, lng: origin.lng),
        );
        expect(calls, 1);
        expect(first, isNotNull);
        expect(second, isNotNull);
        expect(first!.scale, second!.scale);

        final changed = await session.render(
          identity: 2,
          zones: zones.sublist(0, 4),
          viewport: _phone(zoom: 8.2, lat: origin.lat, lng: origin.lng),
        );
        expect(calls, 2);
        expect(changed!.representedChildren, 4);
      },
    );

    test(
      'a zoom band change aggregates again and shares one in-flight job',
      () async {
        var calls = 0;
        final session = HexRenderSession(
          aggregate: (zones, scale) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return aggregateCoverageHexes(zones, scale: scale);
          },
        );
        final zones = _city(rows: 6, cols: 6);
        final origin = hexCellCenter(3, 3);
        final low = session.render(
          identity: 7,
          zones: zones,
          viewport: _phone(zoom: 10, lat: origin.lat, lng: origin.lng),
        );
        final lowAgain = session.render(
          identity: 7,
          zones: zones,
          viewport: _phone(zoom: 10.2, lat: origin.lat, lng: origin.lng + 0.05),
        );
        final plans = await Future.wait(<Future<MapRenderPlan?>>[
          low,
          lowAgain,
        ]);
        expect(calls, 1);
        expect(plans.every((plan) => plan != null), isTrue);

        final high = await session.render(
          identity: 7,
          zones: zones,
          viewport: _phone(zoom: 3, lat: origin.lat, lng: origin.lng),
        );
        expect(calls, 2);
        expect(high!.scale, hexClusterScaleForZoom(3));
      },
    );

    test(
      'an aggregate that finishes after a filter change is ignored',
      () async {
        final gate = Completer<void>();
        final session = HexRenderSession(
          aggregate: (zones, scale) async {
            await gate.future;
            return aggregateCoverageHexes(zones, scale: scale);
          },
        );
        final zones = _city(rows: 4, cols: 4);
        final origin = hexCellCenter(2, 2);
        final pending = session.render(
          identity: 1,
          zones: zones,
          viewport: _phone(zoom: 9, lat: origin.lat, lng: origin.lng),
        );
        session.reset(2);
        gate.complete();
        expect(await pending, isNull);
      },
    );

    test('off-UI aggregation matches the local grouping', () async {
      final zones = <CoverageZone>[
        _zone(id: 'dead', lat: 8, lng: 8, isDeadZone: true, scanCount: 5),
        _zone(
          id: 'good',
          lat: 8,
          lng: 8,
          avgRssi: -95,
          avgSnr: 1,
          scanCount: 1,
        ),
        _zone(id: 'other', lat: 30, lng: 30, avgRssi: -110, avgSnr: -5),
      ];
      final remote = await aggregateCoverageHexesOffUi(zones, scale: 16);
      final local = aggregateCoverageHexes(zones, scale: 16);
      expect(
        remote.map((cluster) => cluster.hitZoneId).toList(),
        local.map((cluster) => cluster.hitZoneId).toList(),
      );
      expect(
        remote.map((cluster) => cluster.childCount).toList(),
        local.map((cluster) => cluster.childCount).toList(),
      );
      expect(
        remote.map((cluster) => cluster.coveredCount).toList(),
        local.map((cluster) => cluster.coveredCount).toList(),
      );
      final home = remote.firstWhere(
        (cluster) => cluster.memberZoneIds.contains('good'),
      );
      expect(home.isDeadZone, isFalse);
      expect(home.hitZoneId, 'good');
      expect(home.childCount, 2);
    });
  });
}
