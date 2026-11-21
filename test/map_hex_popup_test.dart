import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/pages/map_page.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/widgets/map_page_widgets.dart';

CoverageZone _zone({Set<String> nodeIds = const <String>{}}) {
  const lat = 40.79;
  const lng = -77.86;
  return CoverageZone(
    id: hexKey(lat, lng),
    centerLat: lat,
    centerLng: lng,
    radiusMeters: 100,
    avgRssi: -80,
    avgSnr: 5,
    scanCount: 2,
    lastScanned: DateTime.utc(2026, 1, 1),
    isDeadZone: false,
    polygon: getHexVertices(lat, lng),
    nodeIds: nodeIds,
  );
}

Widget _map({
  String? focusHexId,
  List<CoverageZone>? zones,
  VoidCallback? onClearFocusHexId,
  bool syncing = false,
  List<ScanResult> scans = const <ScanResult>[],
  List<RawScan> rawScans = const <RawScan>[],
  Future<List<RawScan>> Function(String zoneId)? onFetchHexDetail,
  void Function(bool Function()? handleBack)? onBackHandler,
}) {
  return MapPage(
    zones: zones ?? <CoverageZone>[_zone()],
    onRefresh: () async {},
    syncing: syncing,
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
    onClearFocusHexId: onClearFocusHexId,
    scans: scans,
    rawScans: rawScans,
    onFetchHexDetail: onFetchHexDetail,
    nodesCount: 0,
    statsRadiusMiles: 0,
    unitSystem: 'imperial',
    tileCachingEnabled: false,
    bleUiEnabled: false,
    observerLat: 40.79,
    observerLng: -77.86,
    onBackHandler: onBackHandler,
  );
}

Widget _app({
  String? focusHexId,
  List<CoverageZone>? zones,
  VoidCallback? onClearFocusHexId,
  void Function(bool Function()? handleBack)? onBackHandler,
}) {
  return MaterialApp(
    home: Scaffold(
      body: _map(
        focusHexId: focusHexId,
        zones: zones,
        onClearFocusHexId: onClearFocusHexId,
        onBackHandler: onBackHandler,
      ),
    ),
  );
}

Future<void> _openFocusedPopup(WidgetTester tester) async {
  final zone = _zone();
  await tester.pumpWidget(
    _app(focusHexId: zone.id, zones: <CoverageZone>[zone]),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  expect(find.text('Coverage Zone'), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('focus is not applied again after dismiss or a rebuild', () {
    expect(
      shouldApplyMapHexFocus(
        focusHexId: 'hex',
        appliedFocusHexId: null,
        suppressed: false,
      ),
      isTrue,
    );
    expect(
      shouldApplyMapHexFocus(
        focusHexId: 'hex',
        appliedFocusHexId: 'hex',
        suppressed: false,
      ),
      isFalse,
    );
    expect(
      shouldApplyMapHexFocus(
        focusHexId: 'hex',
        appliedFocusHexId: null,
        suppressed: true,
      ),
      isFalse,
    );
    expect(
      shouldApplyMapHexFocus(
        focusHexId: null,
        appliedFocusHexId: null,
        suppressed: false,
      ),
      isFalse,
    );
  });

  testWidgets('system back closes the hex popup and then does nothing', (
    tester,
  ) async {
    bool Function()? back;
    final zone = _zone();
    await tester.pumpWidget(
      _app(
        focusHexId: zone.id,
        zones: <CoverageZone>[zone],
        onBackHandler: (handler) => back = handler,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(back, isNotNull);
    expect(back!(), isTrue);
    await tester.pump();
    expect(find.text('Coverage Zone'), findsNothing);
    expect(back!(), isFalse);
  });

  testWidgets('empty map tap dismisses and a zone rebuild does not reopen', (
    tester,
  ) async {
    final zone = _zone();
    await _openFocusedPopup(tester);

    await tester.tapAt(const Offset(40, 400));
    await tester.pump();
    expect(find.text('Coverage Zone'), findsNothing);

    await tester.pumpWidget(
      _app(focusHexId: zone.id, zones: <CoverageZone>[_zone()]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsNothing);

    // A later empty tap stays dismissed (no flicker back open).
    await tester.tapAt(const Offset(80, 420));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Coverage Zone'), findsNothing);
  });

  testWidgets('layer toggle does not re-select after an empty map tap', (
    tester,
  ) async {
    final zone = _zone();
    await _openFocusedPopup(tester);

    await tester.tap(find.byTooltip('Map layers'));
    await tester.pump();
    expect(find.byTooltip('Dark map'), findsOneWidget);
    expect(find.text('Coverage Zone'), findsOneWidget);

    await tester.tapAt(const Offset(40, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Coverage Zone'), findsNothing);

    await tester.pumpWidget(
      _app(focusHexId: zone.id, zones: <CoverageZone>[_zone()]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsNothing);
  });

  testWidgets('sync control does not let a rebuild reopen the popup', (
    tester,
  ) async {
    final zone = _zone();
    await _openFocusedPopup(tester);

    await tester.tap(find.byTooltip('Sync'));
    await tester.pump();
    await tester.tapAt(const Offset(40, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Coverage Zone'), findsNothing);

    await tester.pumpWidget(
      _app(focusHexId: zone.id, zones: <CoverageZone>[_zone()]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsNothing);
  });

  testWidgets('paused lifecycle clears the popup and resume does not restore', (
    tester,
  ) async {
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    final zone = _zone();
    await _openFocusedPopup(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Pausing disables frames, so the cleared popup is not drawn until a
    // frame is forced or the app resumes.
    tester.binding.scheduleForcedFrame();
    await tester.pump();
    expect(find.text('Coverage Zone'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Coverage Zone'), findsNothing);

    await tester.pumpWidget(
      _app(focusHexId: zone.id, zones: <CoverageZone>[_zone()]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsNothing);
  });

  testWidgets('leaving the page clears hex focus so the popup stays closed', (
    tester,
  ) async {
    final zone = _zone();
    final host = _MapHost(zone: zone);
    await tester.pumpWidget(host);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsOneWidget);

    await tester.tap(find.text('Cell History'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Cell History page'), findsOneWidget);
    expect(find.text('Coverage Zone'), findsNothing);

    await tester.tap(find.text('Coverage Map'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsNothing);
  });

  testWidgets('Filter Nodes closes the popup instead of stacking on it', (
    tester,
  ) async {
    // The filter dialog's list is a fixed height. The default 600px test
    // surface is shorter than a phone and overflows that dialog.
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openFocusedPopup(tester);

    await tester.tap(find.byTooltip('Filter repeater hits'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Filter Nodes'), findsOneWidget);
    expect(find.text('Coverage Zone'), findsNothing);
  });
  test('automatic fits never zoom past the basemap native tiles', () {
    expect(basemapMaxNativeZoom, 19);
    expect(capFocusZoom(16.4), 16.4);
    expect(capFocusZoom(19), 19);
    expect(capFocusZoom(21.5), basemapMaxNativeZoom);
    expect(capFocusZoom(double.infinity), basemapMaxNativeZoom);
    expect(capFocusZoom(double.nan), basemapMaxNativeZoom);
  });

  testWidgets('popup shows the observer and SNR in from the cell detail', (
    tester,
  ) async {
    const lat = 40.7967;
    const lng = -77.8747;
    final cell = hexCellAt(lat, lng);
    final id = 'hex:${cell.row}:${cell.col}';
    final when = DateTime.utc(2026, 11, 11, 17, 20, 58);
    final zone = CoverageZone(
      id: id,
      centerLat: lat,
      centerLng: lng,
      radiusMeters: 100,
      avgRssi: -104,
      avgSnr: 9.3,
      scanCount: 6,
      lastScanned: when,
      isDeadZone: false,
      polygon: getHexVertices(lat, lng),
    );
    // Cached map scan without observer identity or SNR in (as loaded from
    // the area history), and the grouped detail row History shows.
    final cached = ScanResult(
      id: 'scan-1',
      observerId: '',
      nodeId: 'F3C072D5',
      rssi: -120,
      snr: -4.25,
      snrIn: null,
      latitude: lat,
      longitude: lng,
      altitude: 342.4,
      timestamp: when,
      senderName: null,
      receiverName: null,
      radioId: null,
    );
    final detail = RawScan(
      observerId: '72A1AC8A',
      radioId: '72A1AC8A',
      nodeId: 'F3C072D5',
      latitude: lat,
      longitude: lng,
      rssi: -120,
      snr: -4.25,
      snrIn: -5.5,
      timestamp: when,
      receiverName: 'KD3CGK Mesh-Utility.org',
      downloadedFromWorker: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _map(
            focusHexId: id,
            zones: <CoverageZone>[zone],
            scans: <ScanResult>[cached],
            onFetchHexDetail: (_) async => <RawScan>[detail],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.textContaining('KD3CGK Mesh-Utility.org'), findsOneWidget);
    expect(find.text('SNR -5.5 dB'), findsOneWidget);
    expect(find.textContaining('unknown'), findsNothing);
  });

  testWidgets('basemap overzooms native tiles instead of going blank', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    final tiles = tester.widget<TileLayer>(find.byType(TileLayer));
    expect(tiles.maxNativeZoom, basemapMaxNativeZoom.toInt());
    // TileLayer renders nothing once zoom rounds above its maxZoom, so it
    // must cover every zoom the map allows.
    expect(tiles.maxZoom, greaterThanOrEqualTo(mapMaxZoom));
    expect(mapMaxZoom, greaterThan(basemapMaxNativeZoom));
    expect(
      tiles.evictErrorTileStrategy,
      EvictErrorTileStrategy.notVisibleRespectMargin,
    );
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(map.options.maxZoom, mapMaxZoom);
  });

  testWidgets('legend matches the drawn hexes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: _map())));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    final dead = tester.widget<LegendRow>(
      find.widgetWithText(LegendRow, 'Dead Zone'),
    );
    expect(dead.color, deadZoneMapColor);
    expect(dead.fillOpacity, legendDeadZoneFillOpacity);
    final swatch = tester.widget<LegendHexSwatch>(
      find.descendant(
        of: find.widgetWithText(LegendRow, 'Dead Zone'),
        matching: find.byType(LegendHexSwatch),
      ),
    );
    expect(swatch.fillOpacity, legendDeadZoneFillOpacity);
    final good = tester.widget<LegendRow>(
      find.widgetWithText(LegendRow, 'Good'),
    );
    expect(good.fillOpacity, legendSignalFillOpacity);
    // Nothing on the map draws the old faint "General / Before Sync" hexes.
    expect(find.text('Before Sync'), findsNothing);
    expect(find.widgetWithText(LegendRow, 'You'), findsOneWidget);
  });

  test('node stat counts heard nodes from the hex index, honoring filters', () {
    final zones = <CoverageZone>[
      _zone(nodeIds: {'F3C072D5AABB', 'aabbccdd'}),
    ];
    expect(scopedNodeKeysFromZones(zones, const <String>{}), {
      'F3C072D5',
      'AABBCCDD',
    });
    expect(scopedNodeKeysFromZones(zones, {'F3C072D5'}), {'F3C072D5'});
    expect(scopedNodeKeysFromZones(zones, {'11223344'}), isEmpty);
  });

  testWidgets('Nodes stat uses indexed cells without raw scans and shows '
      'the radio icon', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _map(
            zones: <CoverageZone>[
              _zone(nodeIds: {'F3C072D5AABB', 'AABBCCDD'}),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final nodesLabel = find.text('Nodes');
    expect(nodesLabel, findsWidgets);
    final card = find.ancestor(
      of: nodesLabel.first,
      matching: find.byType(Card),
    );
    expect(
      find.descendant(of: card.first, matching: find.text('2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card.first, matching: find.text('Offline')),
      findsNothing,
    );
    expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
    expect(find.byTooltip('No radio'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp('No radio')), findsWidgets);
    semantics.dispose();
  });

  testWidgets('missing focus hex recenters, then selects when it arrives', (
    tester,
  ) async {
    const lat = 39.5296;
    const lng = -119.8138;
    final cell = hexCellAt(lat, lng);
    final id = 'hex:${cell.row}:${cell.col}';
    final bounds = hexCellBounds(cell.row, cell.col);
    final centerLat = (bounds.south + bounds.north) / 2;
    final centerLng = (bounds.west + bounds.east) / 2;
    final zone = CoverageZone(
      id: id,
      centerLat: cell.lat,
      centerLng: cell.lng,
      radiusMeters: 100,
      avgRssi: -90,
      avgSnr: 4,
      scanCount: 1,
      lastScanned: DateTime.utc(2026, 6, 1),
      isDeadZone: false,
      polygon: getHexVertices(cell.lat, cell.lng),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _map(focusHexId: id, zones: const <CoverageZone>[]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsNothing);
    final camera = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;
    expect(camera.center.latitude, closeTo(centerLat, 1e-6));
    expect(camera.center.longitude, closeTo(centerLng, 1e-6));
    expect(camera.zoom, capFocusZoom(16.4));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _map(focusHexId: id, zones: <CoverageZone>[zone]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Coverage Zone'), findsOneWidget);
  });

  testWidgets('missing history hexKey still recenters on that cell', (
    tester,
  ) async {
    const lat = 39.5296;
    const lng = -119.8138;
    final id = hexKey(lat, lng);
    final parsed = hexCellAt(lat, lng);
    final bounds = hexCellBounds(parsed.row, parsed.col);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _map(focusHexId: id, zones: const <CoverageZone>[]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final camera = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;
    expect(
      camera.center.latitude,
      closeTo((bounds.south + bounds.north) / 2, 1e-6),
    );
    expect(
      camera.center.longitude,
      closeTo((bounds.west + bounds.east) / 2, 1e-6),
    );
    expect(camera.zoom, capFocusZoom(16.4));
    expect(find.text('Coverage Zone'), findsNothing);
  });

  testWidgets('hex detail fetch errors stay on the popup', (tester) async {
    const lat = 40.7967;
    const lng = -77.8747;
    final cell = hexCellAt(lat, lng);
    final id = 'hex:${cell.row}:${cell.col}';
    final zone = CoverageZone(
      id: id,
      centerLat: cell.lat,
      centerLng: cell.lng,
      radiusMeters: 100,
      avgRssi: -90,
      avgSnr: 4,
      scanCount: 1,
      lastScanned: DateTime.utc(2026, 6, 1),
      isDeadZone: false,
      polygon: getHexVertices(cell.lat, cell.lng),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _map(
            focusHexId: id,
            zones: <CoverageZone>[zone],
            onFetchHexDetail: (_) async => throw StateError('network'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Coverage Zone'), findsOneWidget);
    expect(find.text('Last Scan: unavailable'), findsOneWidget);
    expect(find.text('Loading scan details…'), findsNothing);
  });

  testWidgets('non-finite zone center does not move the camera', (
    tester,
  ) async {
    final zone = CoverageZone(
      id: hexKey(40.79, -77.86),
      centerLat: double.nan,
      centerLng: double.nan,
      radiusMeters: 100,
      avgRssi: -80,
      avgSnr: 5,
      scanCount: 1,
      lastScanned: DateTime.utc(2026, 1, 1),
      isDeadZone: false,
      polygon: getHexVertices(40.79, -77.86),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _map(focusHexId: zone.id, zones: <CoverageZone>[zone]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    final camera = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;
    expect(camera.center.latitude.isFinite, isTrue);
    expect(camera.center.latitude, closeTo(40.79, 1e-4));
    expect(camera.center.longitude, closeTo(-77.86, 1e-4));
    expect(camera.zoom, lessThan(12));
  });

  testWidgets('raw fallback keeps the newer of cache and hex detail', (
    tester,
  ) async {
    const lat = 40.7967;
    const lng = -77.8747;
    final cell = hexCellAt(lat, lng);
    final id = 'hex:${cell.row}:${cell.col}';
    final zone = CoverageZone(
      id: id,
      centerLat: cell.lat,
      centerLng: cell.lng,
      radiusMeters: 100,
      avgRssi: -90,
      avgSnr: 4,
      scanCount: 3,
      lastScanned: DateTime.utc(2024, 6, 15),
      isDeadZone: false,
      polygon: getHexVertices(cell.lat, cell.lng),
    );
    RawScan row(String name, DateTime when, {double? atLat, double? atLng}) {
      return RawScan(
        observerId: '72A1AC8A',
        radioId: '72A1AC8A',
        nodeId: 'F3C072D5',
        latitude: atLat ?? cell.lat,
        longitude: atLng ?? cell.lng,
        rssi: -100,
        snr: 1,
        timestamp: when,
        receiverName: name,
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _map(
            focusHexId: id,
            zones: <CoverageZone>[zone],
            rawScans: <RawScan>[
              row('OlderCache', DateTime.utc(2020, 1, 1)),
              row(
                'FarAway',
                DateTime.utc(2030, 1, 1),
                atLat: cell.lat + 2,
                atLng: cell.lng + 2,
              ),
            ],
            onFetchHexDetail: (_) async => <RawScan>[
              row('AncientDetail', DateTime.utc(2019, 1, 1)),
              row('FromDetail', DateTime.utc(2024, 6, 15)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.textContaining('FromDetail'), findsOneWidget);
    expect(find.textContaining('OlderCache'), findsNothing);
    expect(find.textContaining('AncientDetail'), findsNothing);
    expect(find.textContaining('FarAway'), findsNothing);
  });
}

class _MapHost extends StatefulWidget {
  const _MapHost({required this.zone});

  final CoverageZone zone;

  @override
  State<_MapHost> createState() => _MapHostState();
}

class _MapHostState extends State<_MapHost> {
  int _page = 0;
  String? _focusId;

  @override
  void initState() {
    super.initState();
    _focusId = widget.zone.id;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() => _page = 3),
                  child: const Text('Cell History'),
                ),
                TextButton(
                  onPressed: () => setState(() => _page = 0),
                  child: const Text('Coverage Map'),
                ),
              ],
            ),
            Expanded(
              child: _page == 0
                  ? _map(
                      focusHexId: _focusId,
                      zones: <CoverageZone>[widget.zone],
                      onClearFocusHexId: () {
                        if (!mounted || _page == 0 || _focusId == null) {
                          return;
                        }
                        setState(() => _focusId = null);
                      },
                    )
                  : const Text('Cell History page'),
            ),
          ],
        ),
      ),
    );
  }
}
