import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/pages/history_page.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/radio_id_utils.dart';

void main() {
  const nodeId = '1052A930';
  const longPrefix = '1052A930AABBCCDD';
  const localRadio = '718D349F';
  const remoteRadio = 'BFD65811';
  const lat = 40.8891;
  const lng = -77.481907;

  setUpAll(() async {
    Intl.defaultLocale = 'en_US';
    await initializeDateFormatting('en_US');
  });

  late String hexId;
  setUp(() {
    hexId = hexKey(lat, lng);
  });

  testWidgets(
    'history list keeps scroll offset across parent scan updates',
    (tester) async {
      tester.view.physicalSize = const Size(400, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var scans = _scans(count: 12, hexLat: lat, hexLng: lng, nodeId: nodeId);
      final names = <String, String>{longPrefix: 'TestRep'};

      await tester.pumpWidget(
        _historyApp(scans: scans, names: names, hexId: hexId),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final list = find.byType(Scrollable);
      expect(list, findsOneWidget);
      await tester.drag(list, const Offset(0, -420));
      await tester.pumpAndSettle();
      final before = tester.state<ScrollableState>(list).position.pixels;
      expect(before, greaterThan(80));

      scans = List<ScanResult>.from(scans)
        ..add(
          _scan(
            id: 'scan-extra',
            nodeId: nodeId,
            lat: lat,
            lng: lng,
            minutesAgo: 20,
          ),
        );
      await tester.pumpWidget(
        _historyApp(
          scans: scans,
          names: Map<String, String>.from(names),
          hexId: hexId,
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final after = tester.state<ScrollableState>(list).position.pixels;
      expect(after, closeTo(before, 5));
    },
  );

  testWidgets('unambiguous contact name is shown on a history row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _historyApp(
        scans: _scans(count: 2, hexLat: lat, hexLng: lng, nodeId: nodeId),
        names: <String, String>{longPrefix: 'TestRep'},
        hexId: hexId,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('TestRep'), findsWidgets);
  });

  testWidgets('colliding short prefixes show the hash, not a guessed name', (
    tester,
  ) async {
    await tester.pumpWidget(
      _historyApp(
        scans: _scans(count: 2, hexLat: lat, hexLng: lng, nodeId: nodeId),
        names: <String, String>{
          '1052A93011111111': 'First',
          '1052A93022222222': 'Second',
        },
        hexId: hexId,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('First'), findsNothing);
    expect(find.textContaining('Second'), findsNothing);
    expect(find.textContaining(shortNodeId(nodeId)), findsWidgets);
  });

  testWidgets('a row from another observer is labeled synced', (tester) async {
    final scans = <ScanResult>[
      _scan(
        id: 'local',
        nodeId: nodeId,
        lat: lat,
        lng: lng,
        radioId: localRadio,
        receiverName: 'LocalRadio',
      ),
      _scan(
        id: 'remote',
        nodeId: nodeId,
        lat: lat,
        lng: lng,
        minutesAgo: 3,
        radioId: remoteRadio,
        receiverName: 'OtherObserver',
      ),
    ];
    await tester.pumpWidget(
      _historyApp(
        scans: scans,
        names: const <String, String>{},
        hexId: hexId,
        connectedRadioName: 'LocalRadio',
        connectedRadioMeshId: localRadio,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('synced'), findsWidgets);
    expect(find.textContaining('OtherObserver'), findsWidgets);
    expect(find.text('Cell history'), findsOneWidget);
  });

  testWidgets('one history row uses the singular scan label', (tester) async {
    await tester.pumpWidget(
      _historyApp(
        scans: _scans(count: 1, hexLat: lat, hexLng: lng, nodeId: nodeId),
        names: const <String, String>{},
        hexId: hexId,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('1 scan'), findsOneWidget);
    expect(find.text('1 scans'), findsNothing);
    expect(find.text('Cell history'), findsOneWidget);
  });

  testWidgets('history with no cell filter is titled All Scans', (
    tester,
  ) async {
    await tester.pumpWidget(
      _historyApp(
        scans: _scans(count: 2, hexLat: lat, hexLng: lng, nodeId: nodeId),
        names: const <String, String>{},
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('All Scans'), findsOneWidget);
    expect(find.text('Cell history'), findsNothing);
    expect(find.text('2 scans'), findsOneWidget);
  });

  testWidgets('cell history back is visible without expanding filters', (
    tester,
  ) async {
    await tester.pumpWidget(
      _historyApp(
        scans: _scans(count: 2, hexLat: lat, hexLng: lng, nodeId: nodeId),
        names: const <String, String>{},
        hexId: hexId,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Cell history'), findsOneWidget);
    expect(find.byTooltip('Back to all scans in the cache area'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to all scans in the cache area'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('All Scans'), findsOneWidget);
    expect(find.text('Cell history'), findsNothing);
  });

  testWidgets('clearing initialHexId from the parent leaves All Scans', (
    tester,
  ) async {
    String? selected = hexId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() => selected = null),
                    child: const Text('Open cache area'),
                  ),
                  Expanded(
                    child: HistoryPage(
                      key: const ValueKey<String>('history-page'),
                      scans: _scans(
                        count: 2,
                        hexLat: lat,
                        hexLng: lng,
                        nodeId: nodeId,
                      ),
                      unitSystem: 'imperial',
                      resolvedNodeNames: const <String, String>{},
                      onOpenMapFromHex: (_) {},
                      initialHexId: selected,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Cell history'), findsOneWidget);

    await tester.tap(find.text('Open cache area'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('All Scans'), findsOneWidget);
    expect(find.text('Cell history'), findsNothing);
  });

  testWidgets('pinned hex list shows every grouped event, not a radius slice', (
    tester,
  ) async {
    // Stay under heavyScanCount (250) so the widget test does not call
    // compute(), which can hang pumpAndSettle.
    final scans = _scans(
      count: 40,
      hexLat: lat,
      hexLng: lng,
      nodeId: nodeId,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HistoryPage(
            key: const ValueKey<String>('history-page'),
            scans: scans,
            unitSystem: 'imperial',
            resolvedNodeNames: const <String, String>{},
            onOpenMapFromHex: (_) {},
            initialHexId: hexId,
            pinnedHexList: true,
            // A tight radius around a far-away observer would drop these
            // rows if the pin flag were ignored.
            statsRadiusMiles: 1,
            observerLat: 0,
            observerLng: 0,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Cell history'), findsOneWidget);
    expect(find.text('40 scans'), findsOneWidget);
  });

  testWidgets('a later pinned-list update is not dropped mid-filter', (
    tester,
  ) async {
    var scans = _scans(
      count: 8,
      hexLat: lat,
      hexLng: lng,
      nodeId: nodeId,
    );
    late StateSetter setPageState;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setPageState = setState;
              return HistoryPage(
                key: const ValueKey<String>('history-page'),
                scans: scans,
                unitSystem: 'imperial',
                resolvedNodeNames: const <String, String>{},
                onOpenMapFromHex: (_) {},
                initialHexId: hexId,
                pinnedHexList: true,
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    setPageState(() {
      scans = _scans(
        count: 40,
        hexLat: lat,
        hexLng: lng,
        nodeId: nodeId,
      );
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('40 scans'), findsOneWidget);
  });

}


Widget _historyApp({
  required List<ScanResult> scans,
  required Map<String, String> names,
  String? hexId,
  String? connectedRadioName,
  String? connectedRadioMeshId,
}) {
  return MaterialApp(
    home: Scaffold(
      body: HistoryPage(
        key: const ValueKey<String>('history-page'),
        scans: scans,
        unitSystem: 'imperial',
        resolvedNodeNames: names,
        onOpenMapFromHex: (_) {},
        initialHexId: hexId,
        connectedRadioName: connectedRadioName,
        connectedRadioMeshId: connectedRadioMeshId,
      ),
    ),
  );
}

List<ScanResult> _scans({
  required int count,
  required double hexLat,
  required double hexLng,
  required String nodeId,
}) {
  return <ScanResult>[
    for (var i = 0; i < count; i++)
      _scan(
        id: 'scan-$i',
        nodeId: nodeId,
        lat: hexLat,
        lng: hexLng,
        minutesAgo: i,
      ),
  ];
}

ScanResult _scan({
  required String id,
  required String nodeId,
  required double lat,
  required double lng,
  int minutesAgo = 0,
  String radioId = '718D349F',
  String? receiverName,
}) {
  return ScanResult(
    id: id,
    observerId: radioId,
    nodeId: nodeId,
    rssi: -70,
    snr: 5,
    snrIn: 4,
    latitude: lat,
    longitude: lng,
    altitude: 300,
    timestamp: DateTime.utc(2026, 1, 1, 12).subtract(
      Duration(minutes: minutesAgo),
    ),
    senderName: nodeId,
    receiverName: receiverName ?? radioId,
    radioId: radioId,
  );
}
