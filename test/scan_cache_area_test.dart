import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/pages/scan_cache_area_section.dart';
import 'package:mesh_utility/src/pages/settings_page.dart';
import 'package:mesh_utility/src/services/boundary_catalog.dart';
import 'package:mesh_utility/src/services/division_picker.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/off_ui.dart';
import 'package:mesh_utility/src/services/scan_cache_area.dart';
import 'package:mesh_utility/src/services/scan_cache_service.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(this.files);

  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) {
      throw FlutterError('Missing asset $key');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

const _admin1Fixture = '''
{
  "v": 1,
  "source": "test",
  "countries": [
    {"c": "US", "n": "United States"},
    {"c": "CA", "n": "Canada"}
  ],
  "divisions": [
    {"i": "US:US-CA", "c": "US", "n": "California"},
    {"i": "US:US-NV", "c": "US", "n": "Nevada"},
    {"i": "CA:CA-ON", "c": "CA", "n": "Ontario"}
  ]
}
''';

const _admin2Fixture = '''
{
  "v": 1,
  "source": "test United States only",
  "countries": [{"c": "US", "n": "United States"}],
  "states": [
    {"c": "CA", "n": "California"},
    {"c": "NV", "n": "Nevada"}
  ],
  "divisions": [
    {"i": "CA:06037", "c": "CA", "n": "Los Angeles County", "s": "California"},
    {"i": "CA:06075", "c": "CA", "n": "San Francisco County", "s": "California"},
    {"i": "NV:32003", "c": "NV", "n": "Clark County", "s": "Nevada"}
  ]
}
''';

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
      expect(counties.countries.map((country) => country.code), <String>['US']);
      expect(counties.regions.map((region) => region.code), contains('CA'));
      expect(
        counties.regions
            .firstWhere((region) => region.code == 'CA')
            .countryCode,
        'US',
      );
      expect(admin1.regions, isEmpty);
      expect(counties.source, contains('United States only'));

      final states = buildDivisionPickerTree(admin1);
      final unitedStates = states.singleWhere(
        (node) => node.key == 'country:US',
      );
      expect(unitedStates.leafIds, contains('US:US-CA'));
      expect(
        unitedStates.children.map((node) => node.key),
        contains('div:US:US-CA'),
      );
      expect(
        states.every((node) => node.children.every((child) => child.isLeaf)),
        isTrue,
      );

      final countyTree = buildDivisionPickerTree(counties);
      expect(countyTree.map((node) => node.key), <String>['country:US']);
      final california = countyTree.single.children.singleWhere(
        (node) => node.key == 'region:US:CA',
      );
      expect(california.leafIds, contains('CA:06075'));
      expect(countyTree.single.leafIds, contains('CA:06075'));
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
    expect(find.text('50 miles'), findsOneWidget);
    expect(find.text(scanCacheStorageNote), findsOneWidget);
    expect(find.byType(ScanCacheAreaSection), findsOneWidget);
  });

  testWidgets('Global download pack warns and requires confirm', (tester) async {
    tester.view.physicalSize = const Size(900, 8000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var downloads = 0;
    final globalSettings = AppSettings.defaults.copyWith(
      scanCacheMode: scanCacheModeGlobal,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            settings: globalSettings,
            onChanged: (_) async {},
            onSync: () async {},
            onDownloadCoveragePack: () async {
              downloads += 1;
            },
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
            currentVersionLabel: 'Alpha-25',
          ),
        ),
      ),
    );
    await tester.pump();

    final downloadBtn = find.byKey(const Key('downloadCoveragePackButton'));
    expect(downloadBtn, findsOneWidget);
    await tester.ensureVisible(downloadBtn);
    await tester.tap(downloadBtn);
    await tester.pumpAndSettle();

    expect(find.text('Download entire worldwide pack?'), findsOneWidget);
    expect(downloads, 0);

    await tester.tap(find.byKey(const Key('downloadCoveragePackCancel')));
    await tester.pumpAndSettle();
    expect(downloads, 0);

    await tester.tap(downloadBtn);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('downloadCoveragePackConfirm')));
    await tester.pumpAndSettle();
    expect(downloads, 1);
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
  });

  test('legacy sync radius migrates without shrinking the area', () {
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


  test('stored travel-download settings are ignored and not written back', () {
    final loaded = AppSettings.fromJson(<String, dynamic>{
      'travelDownloadEnabled': true,
      'travelRadiusMiles': 50,
      'travelAnchors': <Map<String, Object>>[
        <String, Object>{
          'latitude': 40.7,
          'longitude': -74.0,
          'radiusMiles': 25,
          'fetchedAtMillis': 1,
        },
      ],
    });
    final json = loaded.toJson();
    expect(json.containsKey('travelDownloadEnabled'), isFalse);
    expect(json.containsKey('travelRadiusMiles'), isFalse);
    expect(json.containsKey('travelAnchors'), isFalse);
  });

  group('division picker select all', () {
    bool? checkValue(WidgetTester tester, String key) {
      return tester
          .widget<Checkbox>(find.byKey(Key('division-check-$key')))
          .value;
    }

    String selectAllLabel(WidgetTester tester, String key) {
      final button = tester.widget<TextButton>(
        find.byKey(Key('division-select-all-$key')),
      );
      return (button.child! as Text).data ?? '';
    }

    Future<void> openPicker(WidgetTester tester, String button) async {
      await tester.tap(find.text(button));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('Done (0)').evaluate().isNotEmpty ||
            find.textContaining('Done (').evaluate().isNotEmpty) {
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            return;
          }
        }
      }
      fail('Division picker did not open');
    }

    Future<void> pumpSection(
      WidgetTester tester, {
      required AppSettings settings,
      required BoundaryCatalog catalog,
      required Future<void> Function(AppSettings value) onChanged,
    }) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScanCacheAreaSection(
              settings: settings,
              onChanged: onChanged,
              catalog: catalog,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    test('tri-state select all follows descendant leaves', () {
      final index = boundaryIndexFromDecoded(jsonDecode(_admin1Fixture));
      final roots = buildDivisionPickerTree(index);
      final unitedStates = roots.singleWhere(
        (node) => node.key == 'country:US',
      );
      final canada = roots.singleWhere((node) => node.key == 'country:CA');
      final selected = <String>{};

      expect(divisionSelectionState(selected, unitedStates.leafIds), isFalse);
      toggleDivisionSelection(selected, unitedStates.leafIds);
      expect(selected, <String>{'US:US-CA', 'US:US-NV'});
      expect(divisionSelectionState(selected, unitedStates.leafIds), isTrue);
      expect(divisionSelectionState(selected, canada.leafIds), isFalse);

      selected.remove('US:US-NV');
      expect(divisionSelectionState(selected, unitedStates.leafIds), isNull);
      expect(
        expandedKeysForPartialSelection(roots, selected),
        contains('country:US'),
      );

      toggleDivisionSelection(selected, unitedStates.leafIds);
      expect(selected, containsAll(<String>['US:US-CA', 'US:US-NV']));
      toggleDivisionSelection(selected, unitedStates.leafIds);
      expect(selected, isEmpty);

      final counties = boundaryIndexFromDecoded(jsonDecode(_admin2Fixture));
      expect(counties.countries.single.code, 'US');
      expect(counties.regions.map((region) => region.code), contains('CA'));
      final tree = buildDivisionPickerTree(counties);
      expect(tree.single.key, 'country:US');
      final california = tree.single.children.singleWhere(
        (node) => node.key == 'region:US:CA',
      );
      final nevada = tree.single.children.singleWhere(
        (node) => node.key == 'region:US:NV',
      );
      toggleDivisionSelection(selected, california.leafIds);
      expect(selected, <String>{'CA:06037', 'CA:06075'});
      expect(divisionSelectionState(selected, nevada.leafIds), isFalse);
      expect(divisionSelectionState(selected, tree.single.leafIds), isNull);
      selected.add('NV:32003');
      expect(divisionSelectionState(selected, tree.single.leafIds), isTrue);
    });

    testWidgets('states list keeps siblings visible and persists ids', (
      tester,
    ) async {
      final catalog = BoundaryCatalog(
        bundle: _MemoryBundle(const <String, String>{
          'assets/boundaries/admin1/index.json': _admin1Fixture,
        }),
      );
      await tester.runAsync(catalog.loadAdmin1Index);
      AppSettings settings = AppSettings.defaults.copyWith(
        scanCacheMode: scanCacheModeAdmin1,
      );
      await pumpSection(
        tester,
        settings: settings,
        catalog: catalog,
        onChanged: (value) async {
          settings = value;
        },
      );
      await openPicker(tester, 'Choose states and provinces (0)');
      expect(find.text('United States'), findsOneWidget);
      expect(find.text('Canada'), findsOneWidget);
      expect(find.text('California'), findsNothing);

      await tester.tap(find.byKey(const Key('division-expand-country:US')));
      await tester.pump();
      expect(find.text('California'), findsOneWidget);
      expect(find.text('Nevada'), findsOneWidget);
      expect(find.text('Canada'), findsOneWidget);
      expect(checkValue(tester, 'country:US'), isFalse);

      await tester.tap(find.byKey(const Key('division-select-all-country:US')));
      await tester.pump();
      expect(checkValue(tester, 'country:US'), isTrue);
      expect(checkValue(tester, 'div:US:US-CA'), isTrue);
      expect(checkValue(tester, 'div:US:US-NV'), isTrue);
      expect(checkValue(tester, 'country:CA'), isFalse);
      expect(selectAllLabel(tester, 'country:US'), 'Clear');

      await tester.tap(find.byKey(const Key('division-select-all-country:US')));
      await tester.pump();
      expect(checkValue(tester, 'country:US'), isFalse);
      expect(checkValue(tester, 'div:US:US-CA'), isFalse);
      expect(checkValue(tester, 'div:US:US-NV'), isFalse);

      await tester.tap(find.byKey(const Key('division-check-div:US:US-CA')));
      await tester.pump();
      expect(checkValue(tester, 'country:US'), isNull);
      expect(checkValue(tester, 'div:US:US-CA'), isTrue);
      expect(checkValue(tester, 'div:US:US-NV'), isFalse);
      expect(selectAllLabel(tester, 'country:US'), 'Select all');

      await tester.tap(find.text('Done (1)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.scanCacheAdmin1Ids, <String>['US:US-CA']);
      expect(settings.scanCacheAdmin2Ids, isEmpty);
      expect(settings.scanCacheMode, scanCacheModeAdmin1);

      await pumpSection(
        tester,
        settings: settings,
        catalog: catalog,
        onChanged: (value) async {
          settings = value;
        },
      );
      await openPicker(tester, 'Choose states and provinces (1)');
      expect(checkValue(tester, 'country:US'), isNull);
      expect(find.text('California'), findsOneWidget);
      expect(checkValue(tester, 'div:US:US-CA'), isTrue);
      expect(checkValue(tester, 'div:US:US-NV'), isFalse);
      expect(find.text('Canada'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ontario');
      await tester.pump();
      expect(find.text('Ontario'), findsOneWidget);
      expect(find.text('United States'), findsNothing);
      expect(find.text('California'), findsNothing);
    });

    testWidgets('county select all is state then country and keeps saved ids', (
      tester,
    ) async {
      final catalog = BoundaryCatalog(
        bundle: _MemoryBundle(const <String, String>{
          'assets/boundaries/admin2/us/index.json': _admin2Fixture,
        }),
      );
      await tester.runAsync(catalog.loadAdmin2Index);
      AppSettings settings = AppSettings.defaults.copyWith(
        scanCacheMode: scanCacheModeAdmin2,
        scanCacheAdmin2Ids: const <String>['NV:32003'],
      );
      await pumpSection(
        tester,
        settings: settings,
        catalog: catalog,
        onChanged: (value) async {
          settings = value;
        },
      );
      await openPicker(tester, 'Choose US counties (1)');
      expect(find.text('United States'), findsOneWidget);
      expect(find.text('California'), findsOneWidget);
      expect(find.text('Nevada'), findsOneWidget);
      expect(checkValue(tester, 'country:US'), isNull);
      expect(checkValue(tester, 'region:US:CA'), isFalse);
      expect(checkValue(tester, 'region:US:NV'), isTrue);

      await tester.tap(find.byKey(const Key('division-expand-region:US:NV')));
      await tester.pump();
      expect(find.text('Clark County'), findsOneWidget);
      expect(checkValue(tester, 'div:NV:32003'), isTrue);
      expect(find.text('United States'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('division-select-all-region:US:CA')),
      );
      await tester.pump();
      expect(checkValue(tester, 'region:US:CA'), isTrue);
      expect(checkValue(tester, 'country:US'), isTrue);
      await tester.tap(find.byKey(const Key('division-expand-region:US:CA')));
      await tester.pump();
      expect(checkValue(tester, 'div:CA:06037'), isTrue);
      expect(checkValue(tester, 'div:CA:06075'), isTrue);

      await tester.tap(find.byKey(const Key('division-select-all-country:US')));
      await tester.pump();
      expect(checkValue(tester, 'country:US'), isFalse);
      expect(checkValue(tester, 'region:US:CA'), isFalse);
      expect(checkValue(tester, 'div:CA:06037'), isFalse);
      expect(checkValue(tester, 'div:NV:32003'), isFalse);

      await tester.tap(
        find.byKey(const Key('division-select-all-region:US:CA')),
      );
      await tester.pump();
      await tester.tap(find.text('Done (2)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.scanCacheAdmin2Ids, <String>['CA:06037', 'CA:06075']);
      expect(settings.scanCacheAdmin1Ids, isEmpty);
      expect(settings.scanCacheMode, scanCacheModeAdmin2);
    });
  });
}
