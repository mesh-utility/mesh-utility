import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/pages/map_page.dart';
import 'package:mesh_utility/src/services/grid.dart';

CoverageZone _zone() {
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
  );
}

Widget _map({
  String? focusHexId,
  List<CoverageZone>? zones,
  VoidCallback? onClearFocusHexId,
  bool syncing = false,
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
    scans: const <ScanResult>[],
    rawScans: const <RawScan>[],
    nodesCount: 0,
    statsRadiusMiles: 0,
    unitSystem: 'imperial',
    tileCachingEnabled: false,
    bleUiEnabled: false,
    observerLat: 40.79,
    observerLng: -77.86,
  );
}

Widget _app({
  String? focusHexId,
  List<CoverageZone>? zones,
  VoidCallback? onClearFocusHexId,
}) {
  return MaterialApp(
    home: Scaffold(
      body: _map(
        focusHexId: focusHexId,
        zones: zones,
        onClearFocusHexId: onClearFocusHexId,
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
