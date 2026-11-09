import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/coverage_overview.dart';
import 'package:mesh_utility/src/services/hex_coverage_aggregate.dart';
import 'package:mesh_utility/src/services/map_camera.dart';

void main() {
  const stateCollege = CoverageOverviewCell(
    row: 152,
    col: -209,
    strength: 4,
    recency: 0,
    countBucket: 1,
  );
  const kansas = CoverageOverviewCell(
    row: 147,
    col: -265,
    strength: 3,
    recency: 1,
    countBucket: 0,
  );

  OverviewLayerPlan plan({
    required List<CoverageOverviewCell> cells,
    required double zoom,
    List<({double lat, double lng})> detailed = const [],
    double south = -85,
    double north = 85,
    double west = -180,
    double east = 180,
    bool spansAllLongitudes = true,
    double centerLat = 39.5,
    double centerLng = -98.35,
  }) {
    return planOverviewLayer(
      cells: cells,
      zoom: zoom,
      detailedCenters: detailed,
      south: south,
      north: north,
      west: west,
      east: east,
      crossesAntimeridian: false,
      spansAllLongitudes: spansAllLongitudes,
      centerLat: centerLat,
      centerLng: centerLng,
    );
  }

  group('parseCoverageOverview', () {
    test('keeps buckets and drops private fields', () {
      final overview = parseCoverageOverview(
        {
          'generatedDay': '2026-11-09',
          'scale': 256,
          'cells': [
            {
              'id': '152:-209',
              's': 4,
              'r': 0,
              'n': 1,
              'radioId': 'SECRET',
              'nodeId': 'abc',
              'name': 'Tower',
              'latitude': 40.7934,
              'longitude': -77.86,
              'lat': 40.79,
              'lng': -77.86,
              'timestamp': '2026-11-09T15:04:00Z',
              'rssi': -80,
              'snr': 12,
              'message': 'hello',
            },
          ],
        },
        fetchedAt: DateTime.utc(2026, 11, 9, 15),
      );

      expect(overview, isNotNull);
      expect(overview!.generatedDay, '2026-11-09');
      expect(overview.scale, mapHexMaxScale);
      final cell = overview.cells.single;
      expect(cell.id, '152:-209');
      expect(cell.center.lat, closeTo(40.8576, 1e-9));
      expect(cell.strength, 4);
      expect(cell.recency, 0);
      expect(cell.countBucket, 1);
      expect(cell.toJson().keys, ['id', 's', 'r', 'n']);
      expect(jsonEncode(cell.toJson()), isNot(contains('SECRET')));
      expect(jsonEncode(cell.toJson()), isNot(contains('40.79')));
    });

    test('rejects a finer scale and a sub-day generatedDay', () {
      expect(
        parseCoverageOverview({
          'scale': 1,
          'cells': [
            {'id': '1:1', 's': 1, 'r': 0},
          ],
        }),
        isNull,
      );
      final overview = parseCoverageOverview({
        'generatedDay': '2026-11-09T15:00:00Z',
        'cells': [
          {'row': 147, 'col': -265, 'strength': 3, 'recency': 1},
          {'id': 'bad', 's': 9, 'r': 0},
          'not-a-cell',
        ],
      }, fetchedAt: DateTime.utc(2026, 11, 9));
      expect(overview!.generatedDay, isNull);
      expect(overview.cells.single.id, '147:-265');
      expect(overview.cells.single.countBucket, isNull);
    });
  });

  group('CoverageOverviewCache', () {
    test('a copy younger than one hour is fresh', () async {
      final now = DateTime.utc(2026, 11, 9, 12);
      Object? stored;
      final cache = CoverageOverviewCache(
        read: () async => stored,
        write: (value) async => stored = value,
        now: () => now,
      );
      await cache.save(
        CoverageOverview(
          cells: const [stateCollege],
          fetchedAt: now.subtract(const Duration(minutes: 59)),
          generatedDay: '2026-11-09',
        ),
      );

      final loaded = await cache.load();
      expect(loaded, isNotNull);
      expect(loaded!.fresh, isTrue);
      expect(loaded.overview.cells.single.id, '152:-209');
      expect(cache.isFresh(now.subtract(overviewCacheTtl)), isFalse);
      expect(
        cache.isFresh(now.subtract(overviewCacheTtl - const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('a one-hour-old JSON string is stale', () async {
      final now = DateTime.utc(2026, 11, 9, 12);
      final raw = jsonEncode({
        'fetchedAt': now.subtract(const Duration(hours: 1)).toIso8601String(),
        'generatedDay': '2026-11-09',
        'scale': 256,
        'cells': [
          {'id': '147:-265', 's': 3, 'r': 1},
        ],
      });
      final cache = CoverageOverviewCache(
        read: () async => raw,
        write: (_) async {},
        now: () => now,
      );

      final loaded = await cache.load();
      expect(loaded!.fresh, isFalse);
      expect(loaded.overview.cells.single.id, '147:-265');
    });

    test('a body without fetchedAt is not a cache hit', () async {
      final cache = CoverageOverviewCache(
        read: () async => {
          'scale': 256,
          'cells': [
            {'id': '1:1', 's': 1, 'r': 0},
          ],
        },
        write: (_) async {},
      );
      expect(await cache.load(), isNull);
    });
  });

  group('overview visibility', () {
    test('shows the layer when nothing detailed is loaded', () {
      final wide = plan(cells: const [stateCollege, kansas], zoom: 4);
      expect(wide.showLayer, isTrue);
      expect(wide.draws.map((draw) => draw.cell.id), [
        '152:-209',
        '147:-265',
      ]);
      expect(wide.draws.first.hitId, 'ov:152:-209');
      expect(wide.draws.first.fill.a, lessThan(0.3));
    });

    test('hides an overview cell that a detailed zone already covers', () {
      final layered = plan(
        cells: const [stateCollege, kansas],
        zoom: 4,
        detailed: const [(lat: 40.7934, lng: -77.86)],
      );
      expect(layered.showLayer, isTrue);
      expect(layered.draws.map((draw) => draw.cell.id), ['147:-265']);
    });

    test('hides the layer once zoomed into detailed data in view', () {
      final hidden = plan(
        cells: const [stateCollege, kansas],
        zoom: mapHexMaxScaleZoom,
        detailed: const [(lat: 40.7934, lng: -77.86)],
      );
      expect(hidden.showLayer, isFalse);
      expect(hidden.draws, isEmpty);
    });

    test('keeps overview hexes when zoomed in away from detailed data', () {
      final away = plan(
        cells: const [stateCollege, kansas],
        zoom: 10,
        detailed: const [(lat: 40.7934, lng: -77.86)],
        south: 38,
        north: 41,
        west: -100,
        east: -97,
        spansAllLongitudes: false,
        centerLat: 39.5,
        centerLng: -98.5,
      );
      expect(away.showLayer, isTrue);
      expect(away.draws.map((draw) => draw.cell.id), ['147:-265']);
    });

    test('still shows overview at a close zoom when there are no zones', () {
      final close = plan(cells: const [kansas], zoom: 10);
      expect(close.showLayer, isTrue);
      expect(close.draws, isNotEmpty);
    });
  });

  group('camera', () {
    test('overview cells do not move the opening camera', () {
      final neutral = mapCameraOnOpen(
        ownLatitude: null,
        ownLongitude: null,
        overviewCells: const [stateCollege, kansas],
      );
      expect(neutral.latitude, neutralMapLatitude);
      expect(neutral.longitude, neutralMapLongitude);
      expect(neutral.latitude, 39.5);
      expect(neutral.longitude, -98.35);
      expect(neutral.zoom, neutralMapZoom);
      expect(neutral.zoom, isNot(stateCollege.center.lat));

      final own = mapCameraOnOpen(
        ownLatitude: 40.7,
        ownLongitude: -77.7,
        overviewCells: const [stateCollege],
      );
      expect(own.latitude, 40.7);
      expect(own.longitude, -77.7);
      expect(own.zoom, ownFixMapZoom);
      expect(own.latitude, isNot(closeTo(stateCollege.center.lat, 0.01)));
    });
  });

  test('the tooltip names strength and recency only', () {
    final text = overviewTooltipText(strength: 4, recency: 0);
    expect(
      text,
      'General coverage (approx.) — Sync or zoom in for details\n'
      'Strong · Past week',
    );
    expect(text, isNot(contains('152')));
    expect(text.toLowerCase(), isNot(contains('scan')));
  });
}
