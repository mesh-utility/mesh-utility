import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/cooperative.dart';
import 'package:mesh_utility/src/services/hex_coverage_aggregate.dart';
import 'package:mesh_utility/src/services/hex_detail.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/src/widgets/map_loading_pill.dart';
import 'package:mesh_utility/transport/transport_core.dart';

class _FakeTransport extends Transport {
  _FakeTransport() : super('fake');

  @override
  bool get isConnected => false;

  @override
  Stream<Uint8List> get inbound => const Stream<Uint8List>.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> send(Uint8List payload) async {}
}

AppState _state() => AppState(
  settingsStore: SettingsStore(),
  localStore: LocalStore(),
  transport: _FakeTransport(),
);

List<HexDetail> _details(int count, {required int row, int col = 3}) {
  return <HexDetail>[
    for (var i = 0; i < count; i++)
      HexDetail(
        row: row + i,
        col: col,
        scanCount: 1 + (i % 4),
        lastTs: 1700000000000 + i,
        bestRssi: -70.0 - (i % 20),
        bestSnr: (i % 9) - 2,
        lastNodeId: 'ab${(i % 1000).toRadixString(16).padLeft(6, '0')}',
      ),
  ];
}

void _expectSameZone(CoverageZone actual, CoverageZone expected) {
  expect(actual.id, expected.id);
  expect(actual.centerLat, expected.centerLat);
  expect(actual.centerLng, expected.centerLng);
  expect(actual.radiusMeters, expected.radiusMeters);
  expect(actual.avgRssi, expected.avgRssi);
  expect(actual.avgSnr, expected.avgSnr);
  expect(actual.scanCount, expected.scanCount);
  expect(actual.lastScanned, expected.lastScanned);
  expect(actual.isDeadZone, expected.isDeadZone);
  expect(actual.nodeIds, expected.nodeIds);
  expect(actual.polygon.length, expected.polygon.length);
  for (var i = 0; i < expected.polygon.length; i++) {
    expect(actual.polygon[i].latitude, expected.polygon[i].latitude);
    expect(actual.polygon[i].longitude, expected.polygon[i].longitude);
  }
}

void _expectSameClusters(
  List<HexCoverageCluster> actual,
  List<HexCoverageCluster> expected,
) {
  expect(actual, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    final a = actual[i];
    final b = expected[i];
    expect(a.scale, b.scale);
    expect(a.row, b.row);
    expect(a.col, b.col);
    expect(a.centerLat, b.centerLat);
    expect(a.centerLng, b.centerLng);
    expect(a.hitZoneId, b.hitZoneId);
    expect(a.isDeadZone, b.isDeadZone);
    expect(a.avgRssi, b.avgRssi);
    expect(a.avgSnr, b.avgSnr);
    expect(a.childCount, b.childCount);
    expect(a.coveredCount, b.coveredCount);
    expect(a.memberZoneIds, b.memberZoneIds);
    expect(a.points.length, b.points.length);
    for (var p = 0; p < b.points.length; p++) {
      expect(a.points[p].latitude, b.points[p].latitude);
      expect(a.points[p].longitude, b.points[p].longitude);
    }
  }
}

CoverageZone _zone({
  required String id,
  required double lat,
  required double lng,
  bool isDeadZone = false,
  double? avgRssi = -80,
  double? avgSnr = 4,
}) {
  return CoverageZone(
    id: id,
    centerLat: lat,
    centerLng: lng,
    radiusMeters: 100,
    avgRssi: avgRssi,
    avgSnr: avgSnr,
    scanCount: 2,
    lastScanned: DateTime.utc(2024, 6, 1),
    isDeadZone: isDeadZone,
    polygon: <LatLng>[
      LatLng(lat - 0.01, lng - 0.01),
      LatLng(lat - 0.01, lng + 0.01),
      LatLng(lat + 0.01, lng),
    ],
  );
}

void main() {
  group('coverage zones async', () {
    test('matches the sync zones', () async {
      final details = <HexDetail>[
        ..._details(300, row: 10),
        _details(1, row: 10).single,
      ];
      final syncZones = coverageZonesFromHexDetails(details);
      final asyncZones = await coverageZonesFromHexDetailsAsync(
        details,
        budget: FrameBudget(budget: Duration.zero),
      );
      expect(asyncZones, isNotNull);
      expect(asyncZones, hasLength(syncZones.length));
      for (var i = 0; i < syncZones.length; i++) {
        _expectSameZone(asyncZones![i], syncZones[i]);
      }
    });

    test('a cancelled build returns null', () async {
      final details = _details(200, row: 0);
      var checks = 0;
      final result = await coverageZonesFromHexDetailsAsync(
        details,
        cancelled: () => ++checks > 30,
        budget: FrameBudget(budget: Duration.zero),
      );
      expect(result, isNull);
      expect(checks, greaterThan(30));
    });
  });

  group('FrameBudget', () {
    test('reads the clock every 64 items and yields when spent', () async {
      final open = FrameBudget(budget: const Duration(hours: 1));
      for (var i = 0; i < 200; i++) {
        expect(identical(open.maybeYield(), FrameBudget.idle), isTrue);
      }

      final spent = FrameBudget(budget: Duration.zero);
      for (var i = 0; i < 63; i++) {
        expect(identical(spent.maybeYield(), FrameBudget.idle), isTrue);
      }
      final turn = spent.maybeYield();
      expect(identical(turn, FrameBudget.idle), isFalse);
      await turn;
      expect(spent.watch.elapsed, lessThan(const Duration(milliseconds: 50)));
    });
  });

  group('AppState tile zones', () {
    test('mapLoading follows the zone build', () async {
      final state = _state();
      final seen = <bool>[];
      state.mapLoading.addListener(() => seen.add(state.mapLoading.value));
      final details = _details(200, row: 0);
      expect(
        state.applyHexIndexToTiles(
          details,
          budget: FrameBudget(budget: Duration.zero),
        ),
        isTrue,
      );
      expect(state.mapLoading.value, isTrue);
      await state.tileZonesSettled;
      expect(state.mapLoading.value, isFalse);
      expect(seen, <bool>[true, false]);
      expect(state.tileCoverageZones, hasLength(200));
    });

    test('a newer index cancels the older build', () async {
      final state = _state();
      var notifies = 0;
      state.addListener(() => notifies++);
      final first = _details(200, row: 0);
      final second = _details(90, row: 10000);
      final budget = FrameBudget(budget: Duration.zero);
      expect(state.applyHexIndexToTiles(first, budget: budget), isTrue);
      expect(state.mapLoading.value, isTrue);
      expect(
        state.applyHexIndexToTiles(
          second,
          budget: FrameBudget(budget: Duration.zero),
        ),
        isTrue,
      );
      await state.tileZonesSettled;
      expect(notifies, 1);
      expect(state.tileCoverageZones, hasLength(90));
      expect(state.tileCoverageZones.first.id, second.first.zoneId);
      expect(state.mapLoading.value, isFalse);
    });
  });

  group('sliced coverage aggregate', () {
    test('matches the sync aggregate', () async {
      final zones = <CoverageZone>[
        _zone(id: 'a', lat: 40.79, lng: -77.86),
        _zone(id: 'b', lat: 40.79001, lng: -77.86001),
        _zone(
          id: 'dead',
          lat: 41.2,
          lng: -76.5,
          isDeadZone: true,
          avgRssi: null,
          avgSnr: null,
        ),
        _zone(id: 'far', lat: 34.0, lng: -118.2, avgRssi: -110, avgSnr: -8),
        _zone(id: 'nan', lat: double.nan, lng: -77.0),
        for (var i = 0; i < 80; i++)
          _zone(id: 'n$i', lat: 42 + i * 0.02, lng: -80 + (i % 5) * 0.01),
      ];
      final budget = FrameBudget(budget: Duration.zero);
      final scale1 = aggregateCoverageHexes(zones, scale: 1);
      final sliced1 = await aggregateCoverageHexesSliced(
        zones,
        scale: 1,
        budget: budget,
      );
      _expectSameClusters(sliced1, scale1);

      final scale16 = aggregateCoverageHexes(zones, scale: 16);
      final sliced16 = await aggregateCoverageHexesSliced(
        zones,
        scale: 16,
        budget: FrameBudget(budget: Duration.zero),
      );
      _expectSameClusters(sliced16, scale16);
    });
  });

  group('loading pill', () {
    testWidgets('waits 300 ms, ignores taps, and hides when idle', (
      tester,
    ) async {
      final busy = ValueNotifier<bool>(false);
      addTearDown(busy.dispose);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => taps++,
                    child: const ColoredBox(color: Color(0xFF101010)),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: MapLoadingPill(busy: <ValueListenable<bool>>[busy]),
                ),
              ],
            ),
          ),
        ),
      );

      busy.value = true;
      await tester.pump();
      expect(find.text('Loading map…'), findsNothing);

      await tester.pump(const Duration(milliseconds: 299));
      expect(find.text('Loading map…'), findsNothing);

      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Loading map…'), findsOneWidget);
      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.strokeWidth, 2);
      final ignore = tester.widget<IgnorePointer>(
        find.descendant(
          of: find.byType(MapLoadingPill),
          matching: find.byWidgetPredicate(
            (widget) => widget is IgnorePointer && widget.ignoring,
          ),
        ),
      );
      expect(ignore.ignoring, isTrue);

      // The pill is under an IgnorePointer, so the tap lands on the map.
      await tester.tap(find.text('Loading map…'), warnIfMissed: false);
      await tester.pump();
      expect(taps, 1);

      busy.value = false;
      await tester.pump();
      expect(find.text('Loading map…'), findsNothing);
    });

    testWidgets('stays hidden when busy ends before 300 ms', (tester) async {
      final busy = ValueNotifier<bool>(true);
      addTearDown(busy.dispose);
      await tester.pumpWidget(
        MaterialApp(home: MapLoadingPill(busy: <ValueListenable<bool>>[busy])),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Loading map…'), findsNothing);
      busy.value = false;
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Loading map…'), findsNothing);
    });
  });
}
