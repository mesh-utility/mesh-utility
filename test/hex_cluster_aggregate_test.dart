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
  group('overview parent scale', () {
    test('scale 256 is the overview preload width', () {
      expect(mapHexMaxScale, 256);
      expect(mapHexMaxScaleZoom, 7.5);
      expect(mapTrueSizeScale, 1);
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

    test('paint draws each filtered zone at its stored size', () {
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

      expect(all.scale, mapTrueSizeScale);
      expect(all.polygons, hasLength(2));
      expect(all.polygons.map((polygon) => polygon.hitZoneId).toSet(), <String>{
        'heard',
        'dead',
      });
      final heardDraw = all.polygons.firstWhere(
        (polygon) => polygon.hitZoneId == 'heard',
      );
      expect(heardDraw.isDeadZone, isFalse);
      expect(heardDraw.scale, mapTrueSizeScale);
      expect(heardDraw.points, heard.polygon);
      expect(heardDraw.memberZoneIds, <String>['heard']);
      expect(filtered.polygons, hasLength(1));
      expect(filtered.polygons.single.isDeadZone, isTrue);
      expect(filtered.polygons.single.hitZoneId, 'dead');
      expect(filtered.polygons.single.points, dead.polygon);
      expect(filtered.polygons.single.memberZoneIds, <String>['dead']);
      expect(filtered.representedChildren, 1);
    });
  });

  group('true-size map paint', () {
    List<CoverageZone> spacedGrid({
      required int rowMin,
      required int rowMax,
      required int colMin,
      required int colMax,
    }) {
      final zones = <CoverageZone>[];
      for (var row = rowMin; row <= rowMax; row++) {
        for (var col = colMin; col <= colMax; col++) {
          final center = hexCellCenter(row, col);
          zones.add(_zone(id: 'r$row:c$col', lat: center.lat, lng: center.lng));
        }
      }
      return zones;
    }

    test('every zoom draws stored cells and keeps every in-view hex', () {
      final zones = _city(rows: 40, cols: 40);
      final byId = <String, CoverageZone>{
        for (final zone in zones) zone.id: zone,
      };
      final center = hexCellCenter(20, 20);
      for (final zoom in <double>[3, 8, 12, 16]) {
        final viewport = _phone(zoom: zoom, lat: center.lat, lng: center.lng);
        final plan = planZonesForMapRender(zones: zones, viewport: viewport);
        expect(plan.scale, mapTrueSizeScale, reason: 'zoom $zoom');
        final drawn = <String>{};
        for (final polygon in plan.polygons) {
          expect(polygon.scale, mapTrueSizeScale, reason: 'zoom $zoom');
          final zone = byId[polygon.hitZoneId];
          expect(zone, isNotNull, reason: polygon.hitZoneId);
          expect(polygon.points, zone!.polygon, reason: 'zoom $zoom');
          expect(polygon.memberZoneIds, <String>[zone.id]);
          expect(drawn.add(polygon.hitZoneId), isTrue);
        }
        for (final zone in zones) {
          if (viewport.containsLatLng(zone.centerLat, zone.centerLng)) {
            expect(drawn, contains(zone.id), reason: 'zoom $zoom ${zone.id}');
          }
        }
        expect(plan.representedChildren, plan.polygons.length);
      }
    });

    test('a world view draws every filtered cell at true size', () {
      final zones = _city(rows: 30, cols: 30);
      expect(zones.length, greaterThan(700));
      final plan = planZonesForMapRender(zones: zones, viewport: _world(3));
      expect(plan.scale, mapTrueSizeScale);
      expect(plan.polygons, hasLength(zones.length));
      expect(plan.representedChildren, zones.length);
      expect(
        plan.polygons.every((polygon) => polygon.scale == mapTrueSizeScale),
        isTrue,
      );
      final ids = plan.polygons.map((polygon) => polygon.hitZoneId).toSet();
      expect(ids, zones.map((zone) => zone.id).toSet());
    });

    test('zoom does not change stored geometry', () {
      final zones = _city(rows: 6, cols: 6);
      final plans = <MapRenderPlan>[
        for (final zoom in <double>[
          mapHexMaxScaleZoom,
          mapHexMaxScaleZoom - 0.01,
          0,
          -2,
          16,
        ])
          planZonesForMapRender(zones: zones, viewport: _world(zoom)),
      ];
      for (final plan in plans) {
        expect(plan.scale, mapTrueSizeScale);
        expect(plan.polygons, hasLength(zones.length));
        expect(plan.representedChildren, zones.length);
      }
      final first = plans.first.polygons.map((polygon) => polygon.points);
      for (final plan in plans.skip(1)) {
        expect(plan.polygons.map((polygon) => polygon.points), first);
      }
    });

    test(
      'a dense view keeps every true-size cell including the corners',
      () async {
        final scales = <int>[];
        final session = HexRenderSession(
          aggregate: (zones, scale) async {
            scales.add(scale);
            return aggregateCoverageHexes(zones, scale: scale);
          },
        );
        final zones = spacedGrid(
          rowMin: -20,
          rowMax: 20,
          colMin: -10,
          colMax: 10,
        );
        expect(zones.length, greaterThan(700));
        final plan = await session.render(
          identity: 1,
          zones: zones,
          viewport: _world(16),
        );

        expect(scales, <int>[mapTrueSizeScale]);
        expect(plan, isNotNull);
        expect(plan!.scale, mapTrueSizeScale);
        expect(plan.polygons, hasLength(zones.length));
        expect(plan.representedChildren, zones.length);
        expect(
          plan.polygons.every(
            (polygon) =>
                polygon.scale == mapTrueSizeScale && polygon.points.length == 6,
          ),
          isTrue,
        );
        final kept = plan.polygons.map((polygon) => polygon.hitZoneId).toSet();
        expect(kept, contains('r0:c0'));
        expect(kept, contains('r20:c10'));
        expect(kept, contains('r-20:c-10'));
      },
    );

    test('culling drops cells outside the viewport and keeps the rest', () {
      final zones = spacedGrid(
        rowMin: -25,
        rowMax: 25,
        colMin: -15,
        colMax: 15,
      );
      const farNorthLat = 70.0;
      const farEastLng = 120.0;
      zones.add(_zone(id: 'far-north', lat: farNorthLat, lng: 0));
      zones.add(_zone(id: 'far-east', lat: 0, lng: farEastLng));
      final center = hexCellCenter(0, 0);
      final viewport = _phone(zoom: 6, lat: center.lat, lng: center.lng);
      final plan = planZonesForMapRender(zones: zones, viewport: viewport);

      expect(plan.scale, mapTrueSizeScale);
      final ids = plan.polygons.map((polygon) => polygon.hitZoneId).toSet();
      expect(ids, contains('r0:c0'));
      expect(ids, isNot(contains('far-north')));
      expect(ids, isNot(contains('far-east')));
      expect(viewport.containsLatLng(farNorthLat, 0), isFalse);
      expect(viewport.containsLatLng(0, farEastLng), isFalse);
      var inView = 0;
      for (final zone in zones) {
        if (!viewport.containsLatLng(zone.centerLat, zone.centerLng)) continue;
        inView++;
        expect(ids, contains(zone.id));
      }
      expect(inView, greaterThan(0));
      expect(plan.polygons.length, greaterThanOrEqualTo(inView));
      expect(
        plan.polygons.every((polygon) => polygon.scale == mapTrueSizeScale),
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
      'concurrent renders share one aggregate and zoom does not aggregate again',
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
        expect(plans.every((plan) => plan!.scale == mapTrueSizeScale), isTrue);

        final high = await session.render(
          identity: 7,
          zones: zones,
          viewport: _phone(zoom: 3, lat: origin.lat, lng: origin.lng),
        );
        expect(calls, 1);
        expect(high!.scale, mapTrueSizeScale);
        expect(
          high.polygons.every((polygon) => polygon.scale == mapTrueSizeScale),
          isTrue,
        );
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
