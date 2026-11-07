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
      expect(hexClusterScaleForZoom(7.5), 256);
      expect(hexClusterScaleForZoom(6.5), 512);
      expect(hexClusterScaleForZoom(5.5), 1024);
      expect(hexClusterScaleForZoom(4.5), 2048);
      expect(hexClusterScaleForZoom(3.5), 4096);
      expect(hexClusterScaleForZoom(3), 8192);
      expect(hexClusterScaleForZoom(2.5), 8192);
      expect(hexClusterScaleForZoom(1.5), 16384);
      expect(hexClusterScaleForZoom(0.5), 32768);
      expect(hexClusterScaleForZoom(0), 65536);
      expect(coarserHexScale(1), 2);
      expect(coarserHexScale(65536), 131072);
      expect(coarserHexScale(mapHexClusterMaxScale), isNull);
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
      expect(plan.nominalScale, 8192);
      expect(plan.usedEmergencyBackstop, isFalse);
      expect(plan.droppedChildren, isFalse);
      expect(plan.representedChildren, zones.length);
      expect(plan.polygons.length, lessThan(20));
      final ids = plan.polygons
          .expand((polygon) => polygon.memberZoneIds)
          .toSet();
      expect(ids, zones.map((zone) => zone.id).toSet());
    });
  });

  group('emergency backstop', () {
    List<CoverageZone> worldParents(int scale) {
      final zones = <CoverageZone>[];
      final rowSpace = rowSpacing * scale;
      final maxRow = (80 / rowSpace).floor();
      final colSpace = colSpacing * scale;
      final maxCol = (180 / colSpace).floor();
      for (var row = -maxRow; row <= maxRow; row++) {
        for (var col = -maxCol; col <= maxCol; col++) {
          final center = hexCellCenter(row, col, scale: scale);
          if (center.lat.abs() > 80 || center.lng.abs() > 180) continue;
          zones.add(_zone(id: 'p$row:$col', lat: center.lat, lng: center.lng));
        }
      }
      return zones;
    }

    test('coarsens past the zoom band instead of dropping children', () {
      const nominal = 4096;
      expect(hexClusterScaleForZoom(4), nominal);
      final zones = worldParents(nominal);
      expect(zones.length, greaterThan(mapMaxDrawnPolygons));
      final plan = planZonesForMapRender(zones: zones, viewport: _world(4));

      expect(plan.nominalScale, nominal);
      expect(plan.scale, greaterThan(nominal));
      expect(plan.usedEmergencyBackstop, isTrue);
      expect(plan.droppedChildren, isFalse);
      expect(plan.polygons.length, lessThanOrEqualTo(mapMaxDrawnPolygons));
      expect(plan.polygons.length, greaterThan(1));
      expect(plan.representedChildren, zones.length);
      expect(
        plan.polygons.expand((polygon) => polygon.memberZoneIds).toSet(),
        zones.map((zone) => zone.id).toSet(),
      );
    });

    test('hard cap is the last resort and can pin a cell it would drop', () {
      const nominal = 4096;
      final zones = worldParents(nominal);
      final capped = planZonesForMapRender(
        zones: zones,
        viewport: _world(4),
        maxScale: nominal,
      );
      expect(capped.usedEmergencyBackstop, isTrue);
      expect(capped.droppedChildren, isTrue);
      expect(capped.polygons, hasLength(mapMaxDrawnPolygons));
      expect(capped.representedChildren, lessThan(zones.length));
      expect(capped.representedChildren, greaterThan(0));

      final kept = capped.polygons
          .expand((polygon) => polygon.memberZoneIds)
          .toSet();
      final missing = zones
          .map((zone) => zone.id)
          .firstWhere((id) => !kept.contains(id));
      final pinned = planZonesForMapRender(
        zones: zones,
        viewport: _world(4),
        maxScale: nominal,
        pinZoneId: missing,
      );
      expect(pinned.polygons, hasLength(mapMaxDrawnPolygons));
      expect(
        pinned.polygons.any((polygon) => polygon.containsZone(missing)),
        isTrue,
      );
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
