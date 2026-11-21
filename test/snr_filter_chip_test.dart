import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/pages/map_page.dart';
import 'package:mesh_utility/src/services/grid.dart';

CoverageZone _zone({
  required double lat,
  required double lng,
  double? snr,
  bool dead = false,
}) {
  return CoverageZone(
    id: hexKey(lat, lng),
    centerLat: lat,
    centerLng: lng,
    radiusMeters: 100,
    avgRssi: dead ? null : -90,
    avgSnr: snr,
    scanCount: 1,
    lastScanned: DateTime.utc(2026, 1, 1),
    isDeadZone: dead,
    polygon: getHexVertices(lat, lng),
  );
}

final _weakZone = _zone(lat: 40.79, lng: -77.86, snr: -10);
final _strongZone = _zone(lat: 40.80, lng: -77.87, snr: 5);
final _deadZone = _zone(lat: 40.81, lng: -77.88, dead: true);

Widget _map({
  List<CoverageZone>? zones,
  String initialSnrFilter = 'all',
  ValueChanged<String>? onSnrFilterChanged,
}) {
  return MapPage(
    zones: zones ?? <CoverageZone>[_weakZone, _strongZone, _deadZone],
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
    scans: const <ScanResult>[],
    rawScans: const <RawScan>[],
    nodesCount: 0,
    statsRadiusMiles: 0,
    unitSystem: 'imperial',
    tileCachingEnabled: false,
    initialSnrFilter: initialSnrFilter,
    onSnrFilterChanged: onSnrFilterChanged,
    bleUiEnabled: false,
    observerLat: 40.79,
    observerLng: -77.86,
  );
}

Widget _app({
  List<CoverageZone>? zones,
  String initialSnrFilter = 'all',
  ValueChanged<String>? onSnrFilterChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: _map(
        zones: zones,
        initialSnrFilter: initialSnrFilter,
        onSnrFilterChanged: onSnrFilterChanged,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SNR chip appears for an active filter and clearing restores', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final stored = <String>[];
    await tester.pumpWidget(
      _app(
        initialSnrFilter: 'weak',
        onSnrFilterChanged: stored.add,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('map-snr-filter-chip')), findsOneWidget);
    expect(find.text('SNR: Weak'), findsOneWidget);
    expect(find.text('0 dead'), findsOneWidget);
    expect(find.text('1 dead'), findsNothing);

    await tester.tap(find.byTooltip('Clear signal filter'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('map-snr-filter-chip')), findsNothing);
    expect(find.text('SNR: Weak'), findsNothing);
    expect(find.text('1 dead'), findsOneWidget);
    expect(stored, ['all']);
  });

  testWidgets('SNR dialog Apply shows the chip and Cancel leaves All', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final stored = <String>[];
    await tester.pumpWidget(_app(onSnrFilterChanged: stored.add));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('map-snr-filter-chip')), findsNothing);
    expect(find.text('1 dead'), findsOneWidget);

    await tester.tap(find.byTooltip('Filter by signal'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Filter by signal'), findsWidgets);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Weak'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('map-snr-filter-chip')), findsOneWidget);
    expect(find.text('SNR: Weak'), findsOneWidget);
    expect(find.text('0 dead'), findsOneWidget);
    expect(stored, ['weak']);

    await tester.tap(find.byTooltip('Filter by signal'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('SNR: Weak'), findsOneWidget);
    expect(stored, ['weak']);
  });
}
