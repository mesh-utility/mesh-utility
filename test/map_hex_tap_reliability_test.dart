import 'dart:async';

import 'package:flutter_map/flutter_map.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/pages/map_page.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/map_viewport_render.dart';
import 'package:mesh_utility/src/widgets/coverage_hex_batch_layer.dart';

CoverageZone _zoneAt(
  double lat,
  double lng, {
  int scanCount = 2,
  double? snr = 5,
  bool dead = false,
}) {
  final cell = hexCellAt(lat, lng);
  return CoverageZone(
    id: hexKey(cell.lat, cell.lng),
    centerLat: cell.lat,
    centerLng: cell.lng,
    radiusMeters: 100,
    avgRssi: dead ? null : -80,
    avgSnr: dead ? null : snr,
    scanCount: scanCount,
    lastScanned: DateTime.utc(2026, 1, 1),
    isDeadZone: dead,
    polygon: getHexVertices(cell.lat, cell.lng),
  );
}

/// The popup prints "Scans: N" only after a scan in the cell is found.
RawScan _scanAt(CoverageZone zone) {
  return RawScan(
    latitude: zone.centerLat,
    longitude: zone.centerLng,
    rssi: -80,
    snr: zone.avgSnr,
    timestamp: DateTime.utc(2026, 1, 1),
    nodeId: '!test',
  );
}

CoverageZone _zoneCell(int row, int col, {int scanCount = 2, double? snr = 5}) {
  final center = hexCellCenter(row, col);
  return CoverageZone(
    id: hexKey(center.lat, center.lng),
    centerLat: center.lat,
    centerLng: center.lng,
    radiusMeters: 100,
    avgRssi: -80,
    avgSnr: snr,
    scanCount: scanCount,
    lastScanned: DateTime.utc(2026, 1, 1),
    isDeadZone: false,
    polygon: getHexVertices(center.lat, center.lng),
  );
}

Widget _map({
  required List<CoverageZone> zones,
  String? focusHexId,
  String initialSnrFilter = 'all',
  double? observerLat,
  double? observerLng,
  List<RawScan> rawScans = const <RawScan>[],
}) {
  return MapPage(
    zones: zones,
    onRefresh: () async {},
    syncing: false,
    forceOffline: false,
    bleConnected: false,
    bleBusy: false,
    bleStatus: 'Disconnected',
    bleScanning: false,
    bleScanStatus: '',
    bleDiscoveries: 0,
    bleNextScanCountdown: null,
    bleLastDiscoverAt: null,
    bleLastDiscoverCount: 0,
    bleLastDiscoverError: null,
    autoCenter: false,
    onToggleAutoCenter: (_) async {},
    onBleConnect: () async {},
    onBleDisconnect: () async {},
    onBleNodeDiscover: () async {},
    onBleToggleScan: () async {},
    onOpenHistoryFromZone: (_) {},
    focusHexId: focusHexId,
    scans: const <ScanResult>[],
    rawScans: rawScans,
    nodesCount: 0,
    statsRadiusMiles: 0,
    unitSystem: 'imperial',
    tileCachingEnabled: false,
    initialSnrFilter: initialSnrFilter,
    bleUiEnabled: false,
    observerLat: observerLat,
    observerLng: observerLng,
  );
}

Widget _app({
  required List<CoverageZone> zones,
  String? focusHexId,
  String initialSnrFilter = 'all',
  double? observerLat,
  double? observerLng,
  List<RawScan> rawScans = const <RawScan>[],
}) {
  return MaterialApp(
    home: Scaffold(
      body: _map(
        zones: zones,
        focusHexId: focusHexId,
        initialSnrFilter: initialSnrFilter,
        observerLat: observerLat,
        observerLng: observerLng,
        rawScans: rawScans,
      ),
    ),
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(mapViewportMaxWait);
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
  });
  await tester.pump();
}

Future<void> _show(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(app);
  await _flush(tester);
}

MapController _controller(WidgetTester tester) {
  return tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!;
}

void _tapMap(
  WidgetTester tester, {
  required Offset relative,
  required LatLng latLng,
}) {
  final onTap = tester
      .widget<FlutterMap>(find.byType(FlutterMap))
      .options
      .onTap;
  expect(onTap, isNotNull);
  onTap!(TapPosition(relative, relative), latLng);
}

/// A point inside the hex ring and outside the centre-only tap radius.
Offset _interiorTap(MapCamera camera, CoverageZone zone) {
  final center = coverageHexLayerOffset(
    camera,
    LatLng(zone.centerLat, zone.centerLng),
  );
  final vertex = coverageHexLayerOffset(camera, zone.polygon.first);
  final delta = vertex - center;
  expect(
    delta.distance,
    greaterThan(kHexTapRadiusTouch + 6),
    reason: 'zoom ${camera.zoom} leaves the hex smaller than the tap slop',
  );
  return center + delta * (kHexTapRadiusTouch + 4) / delta.distance;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MapPage.debugHoldViewportApply = null;
  });

  tearDown(() {
    MapPage.debugHoldViewportApply = null;
  });

  test('overlay suppress window stays inside the double-tap delay', () {
    expect(
      mapOverlayHitSuppressWindow,
      lessThanOrEqualTo(const Duration(milliseconds: 250)),
    );
    final start = DateTime.utc(2026, 1, 1);
    final until = start.add(mapOverlayHitSuppressWindow);
    expect(hexSelectBlockedAt(null, start), isFalse);
    expect(hexSelectBlockedAt(until, start), isTrue);
    expect(hexSelectBlockedAt(until, until), isTrue);
    expect(
      hexSelectBlockedAt(until, until.add(const Duration(milliseconds: 1))),
      isFalse,
    );
  });

  testWidgets('tap during a pending render still opens that hex', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = hexCellAt(40.79, -77.86);
    final zone = _zoneCell(origin.row, origin.col);
    await _show(
      tester,
      _app(
        zones: <CoverageZone>[zone],
        observerLat: zone.centerLat,
        observerLng: zone.centerLng,
      ),
    );
    _controller(tester).move(LatLng(zone.centerLat, zone.centerLng), 16);
    await _flush(tester);
    await _flush(tester);
    expect(find.byType(CoverageHexBatchLayer), findsOneWidget);

    final hold = Completer<void>();
    MapPage.debugHoldViewportApply = () => hold.future;
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    final refreshed = _zoneCell(origin.row, origin.col, scanCount: 9);
    final scans = <RawScan>[_scanAt(refreshed)];
    await tester.pumpWidget(
      _app(
        zones: <CoverageZone>[refreshed],
        observerLat: zone.centerLat,
        observerLng: zone.centerLng,
        rawScans: scans,
      ),
    );
    await tester.pump();
    expect(find.byType(CoverageHexBatchLayer), findsOneWidget);

    final camera = _controller(tester).camera;
    final tap = _interiorTap(camera, refreshed);
    _tapMap(tester, relative: tap, latLng: camera.screenOffsetToLatLng(tap));
    await tester.pump();
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.textContaining(refreshed.id), findsOneWidget);
    expect(find.text('Scans: 9'), findsOneWidget);

    if (!hold.isCompleted) hold.complete();
    MapPage.debugHoldViewportApply = null;
    await _flush(tester);
  });

  testWidgets('tap after a pan hits a hex before the viewport render lands', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final home = _zoneAt(40.79, -77.86);
    final revealed = _zoneAt(45.79, -77.86, scanCount: 4);
    await _show(
      tester,
      _app(
        zones: <CoverageZone>[home, revealed],
        observerLat: home.centerLat,
        observerLng: home.centerLng,
      ),
    );
    _controller(tester).move(LatLng(home.centerLat, home.centerLng), 16);
    await _flush(tester);
    await _flush(tester);
    expect(find.byType(CoverageHexBatchLayer), findsOneWidget);

    final before = _controller(tester).camera;
    final offscreen = coverageHexLayerOffset(
      before,
      LatLng(revealed.centerLat, revealed.centerLng),
    );
    _tapMap(
      tester,
      relative: offscreen,
      latLng: LatLng(revealed.centerLat, revealed.centerLng),
    );
    await tester.pump();
    expect(find.textContaining(revealed.id), findsNothing);

    final hold = Completer<void>();
    MapPage.debugHoldViewportApply = () => hold.future;
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    _controller(
      tester,
    ).move(LatLng(revealed.centerLat, revealed.centerLng), 16);
    await tester.pump();
    final camera = _controller(tester).camera;
    final tap = coverageHexLayerOffset(
      camera,
      LatLng(revealed.centerLat, revealed.centerLng),
    );
    _tapMap(
      tester,
      relative: tap,
      latLng: LatLng(revealed.centerLat, revealed.centerLng),
    );
    await tester.pump();
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.textContaining(revealed.id), findsOneWidget);
    expect(find.textContaining(home.id), findsNothing);

    if (!hold.isCompleted) hold.complete();
    MapPage.debugHoldViewportApply = null;
    await _flush(tester);
  });

  testWidgets('popup survives a zone-list swap when the cell remains', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final zone = _zoneAt(40.79, -77.86);
    final scans = <RawScan>[_scanAt(zone)];
    await _show(
      tester,
      _app(
        zones: <CoverageZone>[zone],
        focusHexId: zone.id,
        observerLat: zone.centerLat,
        observerLng: zone.centerLng,
        rawScans: scans,
      ),
    );
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.text('Scans: 2'), findsOneWidget);

    final sameCells = _zoneAt(40.79, -77.86);
    await tester.pumpWidget(
      _app(
        zones: <CoverageZone>[sameCells],
        focusHexId: zone.id,
        observerLat: zone.centerLat,
        observerLng: zone.centerLng,
        rawScans: scans,
      ),
    );
    await tester.pump();
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.textContaining(zone.id), findsOneWidget);

    final updated = _zoneAt(40.79, -77.86, scanCount: 7);
    await tester.pumpWidget(
      _app(
        zones: <CoverageZone>[updated],
        focusHexId: zone.id,
        observerLat: zone.centerLat,
        observerLng: zone.centerLng,
        rawScans: scans,
      ),
    );
    await tester.pump();
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.text('Scans: 7'), findsOneWidget);
    expect(find.textContaining(updated.id), findsOneWidget);
  });

  testWidgets(
    'popup closes when the cell vanishes or the SNR filter hides it',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final zone = _zoneAt(40.79, -77.86, snr: 5);
      final other = _zoneAt(45.79, -77.86, snr: 5);
      await _show(
        tester,
        _app(
          zones: <CoverageZone>[zone],
          focusHexId: zone.id,
          observerLat: zone.centerLat,
          observerLng: zone.centerLng,
        ),
      );
      expect(find.text('Coverage Zone'), findsOneWidget);

      await tester.pumpWidget(
        _app(
          zones: <CoverageZone>[other],
          focusHexId: zone.id,
          observerLat: zone.centerLat,
          observerLng: zone.centerLng,
        ),
      );
      await tester.pump();
      expect(find.text('Coverage Zone'), findsNothing);

      final strong = _zoneAt(41.5, -76.5, snr: 5);
      await tester.pumpWidget(
        _app(
          zones: <CoverageZone>[strong],
          focusHexId: strong.id,
          observerLat: strong.centerLat,
          observerLng: strong.centerLng,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Coverage Zone'), findsOneWidget);

      await tester.pumpWidget(
        _app(
          zones: <CoverageZone>[strong],
          focusHexId: strong.id,
          initialSnrFilter: 'weak',
          observerLat: strong.centerLat,
          observerLng: strong.centerLng,
        ),
      );
      await tester.pump();
      expect(find.text('Coverage Zone'), findsNothing);

      final weak = _zoneAt(41.2, -77.2, snr: -10);
      await tester.pumpWidget(
        _app(
          zones: <CoverageZone>[weak],
          focusHexId: weak.id,
          initialSnrFilter: 'weak',
          observerLat: weak.centerLat,
          observerLng: weak.centerLng,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Coverage Zone'), findsOneWidget);

      final hidden = _zoneAt(41.2, -77.2, snr: 5);
      await tester.pumpWidget(
        _app(
          zones: <CoverageZone>[hidden],
          focusHexId: weak.id,
          initialSnrFilter: 'weak',
          observerLat: weak.centerLat,
          observerLng: weak.centerLng,
        ),
      );
      await tester.pump();
      expect(find.text('Coverage Zone'), findsNothing);
    },
  );

  testWidgets('empty map tap while a render is pending does not dismiss', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final zone = _zoneAt(40.79, -77.86);
    final scans = <RawScan>[_scanAt(zone)];
    await _show(
      tester,
      _app(
        zones: <CoverageZone>[zone],
        focusHexId: zone.id,
        observerLat: zone.centerLat,
        observerLng: zone.centerLng,
        rawScans: scans,
      ),
    );
    expect(find.text('Coverage Zone'), findsOneWidget);

    final hold = Completer<void>();
    MapPage.debugHoldViewportApply = () => hold.future;
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    final refreshed = _zoneAt(40.79, -77.86, scanCount: 6);
    await tester.pumpWidget(
      _app(
        zones: <CoverageZone>[refreshed],
        focusHexId: zone.id,
        observerLat: zone.centerLat,
        observerLng: zone.centerLng,
        rawScans: scans,
      ),
    );
    await tester.pump();
    _tapMap(tester, relative: const Offset(2, 2), latLng: const LatLng(0, 0));
    await tester.pump();
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.text('Scans: 6'), findsOneWidget);

    if (!hold.isCompleted) hold.complete();
    MapPage.debugHoldViewportApply = null;
    await _flush(tester);
    await _flush(tester);
    _tapMap(tester, relative: const Offset(2, 2), latLng: const LatLng(0, 0));
    await tester.pump();
    expect(find.text('Coverage Zone'), findsNothing);
  });

  testWidgets('overlay suppress blocks only the tap that follows the press', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final zone = _zoneAt(40.79, -77.86);
    await _show(
      tester,
      _app(
        zones: <CoverageZone>[zone],
        observerLat: zone.centerLat,
        observerLng: zone.centerLng,
      ),
    );
    _controller(tester).move(LatLng(zone.centerLat, zone.centerLng), 16);
    await _flush(tester);
    await _flush(tester);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    final camera = _controller(tester).camera;
    final center = coverageHexLayerOffset(
      camera,
      LatLng(zone.centerLat, zone.centerLng),
    );
    _tapMap(
      tester,
      relative: center,
      latLng: LatLng(zone.centerLat, zone.centerLng),
    );
    await tester.pump();
    expect(find.text('Coverage Zone'), findsNothing);

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    _tapMap(
      tester,
      relative: center,
      latLng: LatLng(zone.centerLat, zone.centerLng),
    );
    await tester.pump();
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.textContaining(zone.id), findsOneWidget);
  });

  testWidgets('closing the node filter does not block the next hex tap', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final zone = _zoneAt(40.79, -77.86);
    await _show(
      tester,
      _app(
        zones: <CoverageZone>[zone],
        observerLat: zone.centerLat,
        observerLng: zone.centerLng,
      ),
    );
    _controller(tester).move(LatLng(zone.centerLat, zone.centerLng), 16);
    await _flush(tester);

    await tester.tap(find.byTooltip('Filter repeater hits'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Filter Nodes'), findsOneWidget);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final camera = _controller(tester).camera;
    final center = coverageHexLayerOffset(
      camera,
      LatLng(zone.centerLat, zone.centerLng),
    );
    _tapMap(
      tester,
      relative: center,
      latLng: LatLng(zone.centerLat, zone.centerLng),
    );
    await tester.pump();
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.textContaining(zone.id), findsOneWidget);
  });

  testWidgets('a stale drawn hex outside the new dataset is not selectable', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = hexCellAt(40.79, -77.86);
    final kept = _zoneCell(origin.row, origin.col);
    final dropped = _zoneCell(origin.row, origin.col + 1);
    await _show(
      tester,
      _app(
        zones: <CoverageZone>[kept, dropped],
        observerLat: kept.centerLat,
        observerLng: kept.centerLng,
      ),
    );
    _controller(tester).move(LatLng(kept.centerLat, kept.centerLng), 16);
    await _flush(tester);
    await _flush(tester);
    final camera = _controller(tester).camera;
    final keptPx = coverageHexLayerOffset(
      camera,
      LatLng(kept.centerLat, kept.centerLng),
    );
    final droppedPx = coverageHexLayerOffset(
      camera,
      LatLng(dropped.centerLat, dropped.centerLng),
    );
    expect((keptPx - droppedPx).distance, greaterThan(kHexTapRadiusTouch + 8));

    final hold = Completer<void>();
    MapPage.debugHoldViewportApply = () => hold.future;
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    await tester.pumpWidget(
      _app(
        zones: <CoverageZone>[_zoneCell(origin.row, origin.col, scanCount: 3)],
        observerLat: kept.centerLat,
        observerLng: kept.centerLng,
      ),
    );
    await tester.pump();
    expect(find.byType(CoverageHexBatchLayer), findsOneWidget);

    _tapMap(
      tester,
      relative: droppedPx,
      latLng: LatLng(dropped.centerLat, dropped.centerLng),
    );
    await tester.pump();
    expect(find.text('Coverage Zone'), findsNothing);

    _tapMap(
      tester,
      relative: keptPx,
      latLng: LatLng(kept.centerLat, kept.centerLng),
    );
    await tester.pump();
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.textContaining(kept.id), findsOneWidget);
    expect(find.textContaining(dropped.id), findsNothing);

    if (!hold.isCompleted) hold.complete();
    MapPage.debugHoldViewportApply = null;
    await _flush(tester);
  });
}
