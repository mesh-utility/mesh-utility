import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/pages/scan_cache_area_section.dart';
import 'package:mesh_utility/src/pages/settings_page.dart';
import 'package:mesh_utility/src/services/boundary_catalog.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/off_ui.dart';
import 'package:mesh_utility/src/services/scan_cache_area.dart';
import 'package:mesh_utility/src/services/scan_cache_service.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

RawScan _scan({
  required double lat,
  required double lng,
  bool downloaded = true,
  bool local = false,
  String nodeId = 'AABBCCDD',
  DateTime? timestamp,
}) {
  return RawScan(
    nodeId: nodeId,
    observerId: '11223344',
    latitude: lat,
    longitude: lng,
    rssi: -70,
    timestamp: timestamp ?? DateTime.utc(2026, 4, 1, 12),
    downloadedFromWorker: downloaded,
    locallyRecorded: local,
  );
}

List<List<List<List<double>>>> _square(
  double west,
  double south,
  double east,
  double north,
) {
  return <List<List<List<double>>>>[
    <List<List<double>>>[
      <List<double>>[
        <double>[west, south],
        <double>[east, south],
        <double>[east, north],
        <double>[west, north],
        <double>[west, south],
      ],
    ],
  ];
}

void main() {
  const centerLat = 37.5;
  const centerLng = -122.0;

  test('radius prune drops distant downloads and keeps the near hex', () {
    final near = _scan(lat: centerLat, lng: centerLng);
    final far = _scan(
      lat: centerLat + 3,
      lng: centerLng,
      nodeId: 'BBBBBBBB',
      timestamp: DateTime.utc(2026, 4, 1, 13),
    );
    final result = pruneScansToCacheArea(
      scans: <RawScan>[near, far],
      mode: scanCacheModeRadius,
      radiusMiles: 50,
      centerLat: centerLat,
      centerLng: centerLng,
    );
    expect(result.dropped, 1);
    expect(result.scans, <RawScan>[near]);
    expect(result.hexMembershipTests, 2);
  });

  test('own local scans stay outside the radius', () {
    final local = _scan(lat: centerLat + 3, lng: centerLng, downloaded: false);
    final recorded = _scan(
      lat: centerLat + 3,
      lng: centerLng,
      downloaded: true,
      local: true,
      nodeId: 'CCCCCCCC',
      timestamp: DateTime.utc(2026, 4, 1, 14),
    );
    final result = pruneScansToCacheArea(
      scans: <RawScan>[local, recorded],
      mode: scanCacheModeRadius,
      radiusMiles: 10,
      centerLat: centerLat,
      centerLng: centerLng,
    );
    expect(result.dropped, 0);
    expect(result.scans, <RawScan>[local, recorded]);
    expect(result.hexMembershipTests, 0);
  });

  test('radius with no known location does not prune', () {
    final far = _scan(lat: 10, lng: 10);
    final result = pruneScansToCacheArea(
      scans: <RawScan>[far],
      mode: scanCacheModeRadius,
      radiusMiles: 10,
    );
    expect(result.dropped, 0);
    expect(result.scans, <RawScan>[far]);
    expect(result.hexMembershipTests, 0);
  });

  test('global keeps every downloaded scan', () {
    final scans = <RawScan>[
      _scan(lat: 1, lng: 1),
      _scan(lat: 40, lng: -70, nodeId: 'DDDDDDDD'),
    ];
    final result = pruneScansToCacheArea(
      scans: scans,
      mode: scanCacheModeGlobal,
      radiusMiles: 10,
      centerLat: 0,
      centerLng: 0,
    );
    expect(result.dropped, 0);
    expect(identical(result.scans, scans), isTrue);
  });

  test('selected admin-1 division keeps only inside hexes', () {
    final inside = _scan(lat: 37.5, lng: -121.5);
    final outside = _scan(
      lat: 41,
      lng: -121.5,
      nodeId: 'EEEEEEEE',
      timestamp: DateTime.utc(2026, 4, 2),
    );
    final result = pruneScansToCacheArea(
      scans: <RawScan>[inside, outside],
      mode: scanCacheModeAdmin1,
      radiusMiles: 50,
      selectedIds: <String>{'US:US-CA'},
      polygonsById: <String, List<List<List<List<double>>>>>{
        'US:US-CA': _square(-122, 37, -121, 38),
      },
    );
    expect(result.scans, <RawScan>[inside]);
    expect(result.dropped, 1);
  });

  test('selected county keeps a point in that county only', () {
    final inside = _scan(lat: 37.2, lng: -121.5);
    final outside = _scan(
      lat: 37.2,
      lng: -120.2,
      nodeId: 'FFFFFFFF',
      timestamp: DateTime.utc(2026, 4, 3),
    );
    final result = pruneScansToCacheArea(
      scans: <RawScan>[inside, outside],
      mode: scanCacheModeAdmin2,
      radiusMiles: 50,
      selectedIds: <String>{'CA:06085'},
      polygonsById: <String, List<List<List<List<double>>>>>{
        'CA:06085': _square(-122, 37, -121, 38),
      },
    );
    expect(result.scans.single.latitude, inside.latitude);
    expect(result.dropped, 1);
  });

  test('empty division selection drops downloads and keeps local scans', () {
    final downloaded = _scan(lat: 37.2, lng: -121.5);
    final local = _scan(
      lat: 37.2,
      lng: -121.5,
      downloaded: false,
      nodeId: 'ABCDE123',
      timestamp: DateTime.utc(2026, 4, 4),
    );
    final result = pruneScansToCacheArea(
      scans: <RawScan>[downloaded, local],
      mode: scanCacheModeAdmin1,
      radiusMiles: 50,
    );
    expect(result.scans, <RawScan>[local]);
    expect(result.hexMembershipTests, 1);
  });

  test('hex membership is shared by scans in the same cell', () {
    final first = _scan(lat: 37.5, lng: -122.0, nodeId: '11111111');
    final second = _scan(
      lat: 37.5 + 0.00001,
      lng: -122.0,
      nodeId: '22222222',
      timestamp: DateTime.utc(2026, 4, 1, 15),
    );
    expect(
      hexKey(first.latitude, first.longitude),
      hexKey(second.latitude, second.longitude),
    );
    final other = _scan(
      lat: 40,
      lng: -122,
      nodeId: '33333333',
      timestamp: DateTime.utc(2026, 4, 1, 16),
    );
    final result = pruneScansToCacheArea(
      scans: <RawScan>[first, second, other],
      mode: scanCacheModeRadius,
      radiusMiles: 50,
      centerLat: centerLat,
      centerLng: centerLng,
    );
    expect(result.hexMembershipTests, 2);
    expect(result.hexMembership.length, 2);
    expect(result.scans, <RawScan>[first, second]);

    final again = pruneScansToCacheArea(
      scans: <RawScan>[first, other],
      mode: scanCacheModeRadius,
      radiusMiles: 50,
      centerLat: centerLat,
      centerLng: centerLng,
      priorMembership: result.hexMembership,
    );
    expect(again.hexMembershipTests, 0);
    expect(again.dropped, 1);
  });

  test('worker entry runs off the UI isolate', () async {
    final kept = _scan(lat: centerLat, lng: centerLng);
    final dropped = _scan(
      lat: centerLat + 3,
      lng: centerLng,
      nodeId: '99999999',
      timestamp: DateTime.utc(2026, 4, 5),
    );
    final result = await runOffUi(pruneScanCacheWorker, <String, Object?>{
      'scans': <RawScan>[kept, dropped],
      'mode': scanCacheModeRadius,
      'radiusMiles': 50,
      'centerLat': centerLat,
      'centerLng': centerLng,
      'selectedIds': const <String>[],
      'geometry': const <Map<String, String>>[],
      'membership': const <String, bool>{},
    }, force: true);
    expect(result.scans, hasLength(1));
    expect(result.scans.single.nodeId, kept.nodeId);
    expect(result.scans.single.latitude, kept.latitude);
    expect(result.hexMembershipTests, 2);
  });

  test('merge keeps locallyRecorded when the worker copy wins', () {
    final local = _scan(lat: 10, lng: 10, downloaded: false, local: true);
    final worker = _scan(lat: 10, lng: 10, downloaded: true);
    final merged = mergeWorkerAndLocalScans(
      workerScans: <RawScan>[worker],
      localScans: <RawScan>[local],
    );
    expect(merged.scans.single.downloadedFromWorker, isTrue);
    expect(merged.scans.single.locallyRecorded, isTrue);
    final pruned = pruneScansToCacheArea(
      scans: merged.scans,
      mode: scanCacheModeRadius,
      radiusMiles: 10,
      centerLat: 40,
      centerLng: -70,
    );
    expect(pruned.dropped, 0);
    expect(pruned.scans, merged.scans);
  });

  test('cache setting defaults to radius 50 miles and round-trips', () {
    expect(AppSettings.defaults.scanCacheMode, scanCacheModeRadius);
    expect(AppSettings.defaults.scanCacheRadiusMiles, 50);
    final settings = AppSettings.defaults.copyWith(
      scanCacheMode: scanCacheModeAdmin1,
      scanCacheRadiusMiles: 250,
      scanCacheAdmin1Ids: <String>['JP:JP-13', 'US:US-CA'],
      scanCacheAdmin2Ids: <String>['CA:06075'],
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.scanCacheMode, scanCacheModeAdmin1);
    expect(restored.scanCacheRadiusMiles, 250);
    expect(restored.scanCacheAdmin1Ids, <String>['JP:JP-13', 'US:US-CA']);
    expect(restored.scanCacheAdmin2Ids, <String>['CA:06075']);

    final legacy = AppSettings.fromJson(<String, dynamic>{'historyDays': 14});
    expect(legacy.scanCacheMode, scanCacheModeRadius);
    expect(legacy.scanCacheRadiusMiles, 50);
    expect(legacy.scanCacheAdmin1Ids, isEmpty);
    expect(legacy.historyDays, 14);
    expect(clampScanCacheRadiusMiles(40), 50);
    expect(clampScanCacheMode('nope'), scanCacheModeRadius);
  });

  test(
    'cache mode and selections persist in the reax settings record',
    () async {
      final dir = await Directory.systemTemp.createTemp('mesh-cache-settings-');
      try {
        final settings = AppSettings.defaults.copyWith(
          scanCacheMode: scanCacheModeAdmin2,
          scanCacheRadiusMiles: 800,
          scanCacheAdmin1Ids: <String>['CA:CA-ON'],
          scanCacheAdmin2Ids: <String>['CA:06075', 'NV:32003'],
        );
        final db = await ReaxDB.simple(dir.path);
        await db.put('settings:app', settings.toJson());
        await db.close();

        final opened = await ReaxDB.simple(dir.path);
        final raw = await opened.get('settings:app');
        await opened.close();
        expect(raw, isA<Map>());
        final loaded = AppSettings.fromJson(
          Map<String, dynamic>.from(raw as Map),
        );
        expect(loaded.scanCacheMode, scanCacheModeAdmin2);
        expect(loaded.scanCacheRadiusMiles, 800);
        expect(loaded.scanCacheAdmin1Ids, <String>['CA:CA-ON']);
        expect(loaded.scanCacheAdmin2Ids, <String>['CA:06075', 'NV:32003']);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test('expansion grows the radius and added divisions, not a shrink', () {
    expect(
      scanCacheAreaExpands(
        previousMode: scanCacheModeRadius,
        nextMode: scanCacheModeRadius,
        previousRadiusMiles: 50,
        nextRadiusMiles: 100,
        previousAdmin1Ids: const <String>[],
        nextAdmin1Ids: const <String>[],
        previousAdmin2Ids: const <String>[],
        nextAdmin2Ids: const <String>[],
      ),
      isTrue,
    );
    expect(
      scanCacheAreaExpands(
        previousMode: scanCacheModeRadius,
        nextMode: scanCacheModeRadius,
        previousRadiusMiles: 100,
        nextRadiusMiles: 50,
        previousAdmin1Ids: const <String>[],
        nextAdmin1Ids: const <String>[],
        previousAdmin2Ids: const <String>[],
        nextAdmin2Ids: const <String>[],
      ),
      isFalse,
    );
    expect(
      scanCacheAreaExpands(
        previousMode: scanCacheModeRadius,
        nextMode: scanCacheModeGlobal,
        previousRadiusMiles: 50,
        nextRadiusMiles: 50,
        previousAdmin1Ids: const <String>[],
        nextAdmin1Ids: const <String>[],
        previousAdmin2Ids: const <String>[],
        nextAdmin2Ids: const <String>[],
      ),
      isTrue,
    );
    expect(
      scanCacheAreaExpands(
        previousMode: scanCacheModeAdmin1,
        nextMode: scanCacheModeAdmin1,
        previousRadiusMiles: 50,
        nextRadiusMiles: 50,
        previousAdmin1Ids: const <String>['US:US-CA'],
        nextAdmin1Ids: const <String>['US:US-CA', 'JP:JP-13'],
        previousAdmin2Ids: const <String>[],
        nextAdmin2Ids: const <String>[],
      ),
      isTrue,
    );
  });

  test('delta ring decoder restores a closed square', () {
    final ring = decodeDeltaRing('-12250,3700 100,0 0,100 -100,0 0,-100', 100);
    expect(ring.first, <double>[-122.5, 37]);
    expect(ring[1], <double>[-121.5, 37]);
    expect(ring[2], <double>[-121.5, 38]);
    expect(ring.last, ring.first);
  });

  test('california and tokyo assets contain known cities', () async {
    final service = ScanCacheService();
    final angeles = _scan(lat: 34.05, lng: -118.24, nodeId: 'CA000001');
    final pacific = _scan(
      lat: 0,
      lng: -160,
      nodeId: 'CA000002',
      timestamp: DateTime.utc(2026, 4, 6),
    );
    final tokyo = _scan(
      lat: 35.6812,
      lng: 139.7671,
      nodeId: 'JP000013',
      timestamp: DateTime.utc(2026, 4, 7),
    );
    final states = AppSettings.defaults.copyWith(
      scanCacheMode: scanCacheModeAdmin1,
      scanCacheAdmin1Ids: <String>['US:US-CA', 'JP:JP-13'],
    );
    final kept = await service.prune(
      scans: <RawScan>[angeles, pacific, tokyo],
      settings: states,
      centerLat: null,
      centerLng: null,
    );
    expect(kept.map((scan) => scan.nodeId).toList(), <String?>[
      'CA000001',
      'JP000013',
    ]);

    final county = AppSettings.defaults.copyWith(
      scanCacheMode: scanCacheModeAdmin2,
      scanCacheAdmin2Ids: <String>['CA:06037'],
    );
    final countyKept = await service.prune(
      scans: <RawScan>[angeles, tokyo],
      settings: county,
      centerLat: null,
      centerLng: null,
    );
    expect(countyKept.single.nodeId, 'CA000001');
  });

  test(
    'boundary index groups divisions and loads off the asset bundle',
    () async {
      final catalog = BoundaryCatalog();
      final admin1 = await catalog.loadAdmin1Index();
      expect(admin1.divisions, isNotEmpty);
      expect(
        admin1.divisions.map((division) => division.id),
        containsAll(<String>['US:US-CA', 'JP:JP-13', 'CA:CA-ON']),
      );
      final japan = admin1.countries.where((country) => country.code == 'JP');
      expect(japan.single.name, 'Japan');
      final counties = await catalog.loadAdmin2Index();
      expect(
        counties.divisions.map((division) => division.id),
        contains('CA:06075'),
      );
      expect(counties.countries.map((country) => country.code), contains('CA'));
      expect(counties.source, contains('United States only'));
    },
  );

  testWidgets('settings show the default radius and the storage note', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 8000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            settings: AppSettings.defaults,
            onChanged: (_) async {},
            onSync: () async {},
            syncing: false,
            localScanCount: 0,
            uploadQueueCount: 0,
            lastSyncAt: null,
            lastSyncScanCount: 0,
            periodicSyncEnabled: false,
            periodicSyncWaitingForInternetTimeAnchor: false,
            nextPeriodicSyncDueAtUtc: null,
            bleConnected: false,
            bleBusy: false,
            debugLogs: const [],
            onClearDebugLogs: () {},
            onClearScanCache: () async {},
            onDownloadOfflineTiles: () async => 0,
            onClearOfflineTiles: () async {},
            onDeleteRadioData: () async {},
            deleteInProgress: false,
            connectedRadioId: null,
            darkMode: true,
            onToggleTheme: () {},
            currentVersionLabel: 'Alpha-22',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Scan cache area'), findsOneWidget);
    expect(find.text('Sync Download Scope'), findsNothing);
    expect(find.text(scanCacheCloudNote), findsOneWidget);
    expect(find.text('Download where I travel'), findsOneWidget);
    expect(find.text('50 miles'), findsOneWidget);
    expect(find.text(scanCacheStorageNote), findsOneWidget);
    expect(find.byType(ScanCacheAreaSection), findsOneWidget);
  });

  testWidgets('county mode explains that only the United States is included', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 8000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScanCacheAreaSection(
            settings: AppSettings.defaults.copyWith(
              scanCacheMode: scanCacheModeAdmin2,
            ),
            onChanged: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text(scanCacheCountyNote), findsOneWidget);
    expect(find.text('Choose US counties (0)'), findsOneWidget);
    expect(find.text('Download where I travel'), findsOneWidget);
    expect(find.text(travelDownloadNote), findsOneWidget);
  });

  test('legacy sync radius migrates without shrinking the area', () {
    expect(AppSettings.defaults.travelDownloadEnabled, isFalse);
    expect(AppSettings.defaults.travelRadiusMiles, 25);
    expect(AppSettings.defaults.toJson()['syncRadiusMiles'], 50);

    AppSettings load(Map<String, dynamic> json) => AppSettings.fromJson(json);

    expect(load(<String, dynamic>{}).scanCacheMode, scanCacheModeRadius);
    expect(load(<String, dynamic>{}).scanCacheRadiusMiles, 50);

    final global = load(<String, dynamic>{'syncRadiusMiles': 0});
    expect(global.scanCacheMode, scanCacheModeGlobal);
    expect(global.toJson()['syncRadiusMiles'], 0);

    final cases = <int, int>{
      1: 10,
      10: 10,
      25: 25,
      40: 50,
      50: 50,
      100: 100,
      250: 250,
      251: 500,
      500: 500,
      800: 800,
      900: 800,
    };
    for (final entry in cases.entries) {
      final migrated = load(<String, dynamic>{'syncRadiusMiles': entry.key});
      expect(
        migrated.scanCacheMode,
        scanCacheModeRadius,
        reason: '${entry.key}',
      );
      expect(
        migrated.scanCacheRadiusMiles,
        entry.value,
        reason: '${entry.key}',
      );
      expect(
        migrated.scanCacheRadiusMiles,
        greaterThanOrEqualTo(entry.key > 800 ? 800 : entry.key),
      );
    }

    final already = load(<String, dynamic>{
      'syncRadiusMiles': 0,
      'scanCacheMode': scanCacheModeRadius,
      'scanCacheRadiusMiles': 100,
    });
    expect(already.scanCacheMode, scanCacheModeRadius);
    expect(already.scanCacheRadiusMiles, 100);
    expect(already.toJson()['syncRadiusMiles'], 100);

    final wide = AppSettings.defaults.copyWith(scanCacheRadiusMiles: 800);
    expect(wide.toJson()['syncRadiusMiles'], workerScanRadiusCapMiles);
    final wideQuery = cloudQueryForCache(
      mode: scanCacheModeRadius,
      radiusMiles: 800,
      centerLat: 36,
      centerLng: -115,
    );
    expect(wideQuery.radiusMiles, 800);
    final wideBox = boundsForRadiusMiles(
      latitude: 36,
      longitude: -115,
      radiusMiles: 800,
    );
    expect(wideQuery.minLatitude, closeTo(wideBox.minLatitude, 1e-9));
    expect(wideQuery.maxLatitude, closeTo(wideBox.maxLatitude, 1e-9));
    expect(wideQuery.minLongitude, closeTo(wideBox.minLongitude, 1e-9));
    expect(wideQuery.maxLongitude, closeTo(wideBox.maxLongitude, 1e-9));
    expect(wideQuery.minLatitude, closeTo(36 - (800 / 69), 1e-9));

    final cappedRadius = cloudQueryForCache(
      mode: scanCacheModeRadius,
      radiusMiles: 50,
      centerLat: 36,
      centerLng: -115,
    );
    expect(cappedRadius.radiusMiles, 50);
    expect(cappedRadius.hasBounds, isFalse);
  });

  test('cloud query follows the cache area and skips an empty selection', () {
    final worldwide = cloudQueryForCache(
      mode: scanCacheModeGlobal,
      radiusMiles: 50,
      centerLat: 1,
      centerLng: 2,
    );
    expect(worldwide.skip, isFalse);
    expect(worldwide.omitsRadius, isTrue);
    expect(worldwide.hasBounds, isFalse);

    final noFix = cloudQueryForCache(
      mode: scanCacheModeRadius,
      radiusMiles: 50,
      centerLat: null,
      centerLng: null,
    );
    expect(noFix.skip, isTrue);

    final empty = cloudQueryForCache(
      mode: scanCacheModeAdmin1,
      radiusMiles: 50,
      centerLat: 10,
      centerLng: 10,
    );
    expect(empty.skip, isTrue);

    final bbox = const DivisionBbox(
      minLatitude: 32,
      minLongitude: -124,
      maxLatitude: 42,
      maxLongitude: -114,
    );
    final around = cloudQueryForCache(
      mode: scanCacheModeAdmin1,
      radiusMiles: 50,
      centerLat: 0,
      centerLng: 0,
      divisionBbox: bbox,
    );
    expect(around.skip, isFalse);
    expect(around.latitude, closeTo(37, 0.001));
    expect(around.longitude, closeTo(-119, 0.001));
    expect(around.radiusMiles, greaterThan(250));
    final corner = distanceMiles(37, -119, 32, -124);
    expect(around.radiusMiles, greaterThanOrEqualTo(corner.ceil()));
    expect(around.minLatitude, 32);
    expect(around.maxLatitude, 42);
    expect(around.minLongitude, -124);
    expect(around.maxLongitude, -114);
    expect(around.hasBounds, isTrue);

    final dateline = cloudQueryForCache(
      mode: scanCacheModeRadius,
      radiusMiles: 800,
      centerLat: 0,
      centerLng: 179,
    );
    expect(dateline.radiusMiles, 800);
    expect(dateline.minLongitude!, greaterThan(dateline.maxLongitude!));

    final polar = cloudQueryForCache(
      mode: scanCacheModeRadius,
      radiusMiles: 800,
      centerLat: 85,
      centerLng: 0,
    );
    expect(polar.maxLatitude, 90);

    final globe = cloudQueryForCache(
      mode: scanCacheModeAdmin1,
      radiusMiles: 50,
      centerLat: 0,
      centerLng: 0,
      divisionBbox: const DivisionBbox(
        minLatitude: -90,
        minLongitude: -180,
        maxLatitude: 90,
        maxLongitude: 180,
      ),
    );
    expect(globe.skip, isFalse);
    expect(globe.omitsRadius, isTrue);
    expect(globe.hasBounds, isFalse);
  });

  test('old-server division query uses a device inside the box', () {
    // Pennsylvania + New York + Ontario style union. The box center is
    // hundreds of miles from a fix in the south of the box.
    const bbox = DivisionBbox(
      minLatitude: 39.7,
      minLongitude: -95.2,
      maxLatitude: 56.9,
      maxLongitude: -74.3,
    );
    const deviceLat = 40.8;
    const deviceLng = -77.6;
    final boxCenterLat = (bbox.minLatitude + bbox.maxLatitude) / 2;
    final boxCenterLng = (bbox.minLongitude + bbox.maxLongitude) / 2;
    expect(
      distanceMiles(deviceLat, deviceLng, boxCenterLat, boxCenterLng),
      greaterThan(250),
    );

    final onDevice = cloudQueryForCache(
      mode: scanCacheModeAdmin1,
      radiusMiles: 50,
      centerLat: deviceLat,
      centerLng: deviceLng,
      divisionBbox: bbox,
    );
    expect(onDevice.latitude, deviceLat);
    expect(onDevice.longitude, deviceLng);
    expect(onDevice.minLatitude, bbox.minLatitude);
    expect(onDevice.maxLatitude, bbox.maxLatitude);
    expect(onDevice.minLongitude, bbox.minLongitude);
    expect(onDevice.maxLongitude, bbox.maxLongitude);
    final corners = <List<double>>[
      <double>[bbox.minLatitude, bbox.minLongitude],
      <double>[bbox.minLatitude, bbox.maxLongitude],
      <double>[bbox.maxLatitude, bbox.minLongitude],
      <double>[bbox.maxLatitude, bbox.maxLongitude],
    ];
    var farthest = 0.0;
    for (final corner in corners) {
      final miles = distanceMiles(deviceLat, deviceLng, corner[0], corner[1]);
      if (miles > farthest) farthest = miles;
    }
    expect(onDevice.radiusMiles, farthest.ceil() + 1);
    expect(onDevice.radiusMiles, greaterThan(250));

    final outside = cloudQueryForCache(
      mode: scanCacheModeAdmin2,
      radiusMiles: 50,
      centerLat: 0,
      centerLng: 0,
      divisionBbox: bbox,
    );
    expect(outside.latitude, closeTo(boxCenterLat, 0.001));
    expect(outside.longitude, closeTo(boxCenterLng, 0.001));
    expect(outside.hasBounds, isTrue);

    final noFix = cloudQueryForCache(
      mode: scanCacheModeAdmin1,
      radiusMiles: 50,
      centerLat: null,
      centerLng: null,
      divisionBbox: bbox,
    );
    expect(noFix.latitude, closeTo(boxCenterLat, 0.001));
    expect(noFix.longitude, closeTo(boxCenterLng, 0.001));
  });

  test(
    'travel fetch triggers only outside the area, and retention keeps it',
    () {
      final now = DateTime.utc(2026, 6, 1, 12);
      TravelFetchDecision decide({
        bool enabled = true,
        bool forceOffline = false,
        bool networkAvailable = true,
        bool syncInFlight = false,
        String mode = scanCacheModeAdmin1,
        bool outside = true,
        double? deviceLat = 40.7,
        double? deviceLng = -74.0,
        double? lastLat,
        double? lastLng,
        DateTime? lastAt,
        DateTime? at,
      }) {
        return decideTravelFetch(
          enabled: enabled,
          forceOffline: forceOffline,
          networkAvailable: networkAvailable,
          syncInFlight: syncInFlight,
          mode: mode,
          outsideCacheArea: outside,
          deviceLat: deviceLat,
          deviceLng: deviceLng,
          lastFetchLat: lastLat,
          lastFetchLng: lastLng,
          lastFetchAt: lastAt,
          now: at ?? now,
        );
      }

      expect(decide().fetch, isTrue);
      expect(decide().reason, 'first');
      expect(decide(outside: false).reason, 'inside');
      expect(decide(mode: scanCacheModeGlobal).reason, 'global');
      expect(decide(forceOffline: true).reason, 'offline');
      expect(decide(networkAvailable: false).reason, 'no-network');
      expect(decide(enabled: false).reason, 'off');
      expect(decide(syncInFlight: true).reason, 'sync-in-flight');

      final recent = decide(
        lastLat: 40.7,
        lastLng: -74.0,
        lastAt: now.subtract(const Duration(minutes: 2)),
        deviceLat: 41.0,
        deviceLng: -74.0,
      );
      expect(recent.reason, 'interval');

      final held = decide(
        lastLat: 40.7,
        lastLng: -74.0,
        lastAt: now.subtract(const Duration(minutes: 6)),
      );
      expect(held.reason, 'not-moved');

      final moved = decide(
        lastLat: 40.0,
        lastLng: -74.0,
        lastAt: now.subtract(const Duration(minutes: 6)),
        deviceLat: 40.2,
        deviceLng: -74.0,
      );
      expect(moved.reason, 'moved');

      final newHex = decide(
        lastLat: 40.700,
        lastLng: -74.000,
        lastAt: now.subtract(const Duration(minutes: 6)),
        deviceLat: 40.702,
        deviceLng: -74.000,
      );
      expect(hexKey(40.700, -74.000) == hexKey(40.702, -74.000), isFalse);
      expect(newHex.reason, 'new-hex');

      final home = _scan(lat: 34.05, lng: -118.24, nodeId: 'HOME0001');
      final trip = _scan(lat: 40.71, lng: -74.01, nodeId: 'TRIP0001');
      final elsewhere = _scan(lat: 0, lng: 0, nodeId: 'FAR00001');
      final anchor = TravelAreaAnchor(
        latitude: 40.71,
        longitude: -74.01,
        radiusMiles: 25,
        fetchedAtMillis: now.millisecondsSinceEpoch,
      );
      final kept = pruneScansToCacheArea(
        scans: <RawScan>[home, trip, elsewhere],
        mode: scanCacheModeRadius,
        radiusMiles: 50,
        centerLat: 34.05,
        centerLng: -118.24,
        travelAreas: <TravelAreaAnchor>[anchor],
      );
      expect(kept.scans.map((scan) => scan.nodeId).toList(), <String?>[
        'HOME0001',
        'TRIP0001',
      ]);
      final dropped = pruneScansToCacheArea(
        scans: <RawScan>[home, trip, elsewhere],
        mode: scanCacheModeRadius,
        radiusMiles: 50,
        centerLat: 34.05,
        centerLng: -118.24,
      );
      expect(dropped.scans.map((scan) => scan.nodeId).toList(), <String?>[
        'HOME0001',
      ]);

      final anchors = <TravelAreaAnchor>[];
      var recorded = anchors;
      for (var i = 0; i < 9; i++) {
        recorded = rememberTravelFetch(
          anchors: recorded,
          latitude: 10 + i.toDouble(),
          longitude: -70,
          radiusMiles: 25,
          now: now.add(Duration(days: i)),
        );
      }
      expect(recorded, hasLength(travelAnchorLimit));
      expect(recorded.any((anchor) => anchor.latitude == 10), isFalse);
      expect(recorded.first.latitude, 18);

      final stale = rememberTravelFetch(
        anchors: <TravelAreaAnchor>[
          TravelAreaAnchor(
            latitude: 1,
            longitude: 1,
            radiusMiles: 25,
            fetchedAtMillis: now
                .subtract(const Duration(days: 31))
                .millisecondsSinceEpoch,
          ),
        ],
        latitude: 50,
        longitude: 50,
        radiusMiles: 10,
        now: now,
      );
      expect(stale, hasLength(1));
      expect(stale.single.latitude, 50);
      expect(stale.single.radiusMiles, 10);
    },
  );
}
