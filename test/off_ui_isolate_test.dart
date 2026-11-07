import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/hex_coverage_aggregate.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/history_scan_filter.dart';
import 'package:mesh_utility/src/services/off_ui.dart';

/// Parent-isolate counter. A worker that increments this and runs under
/// [Isolate.run] leaves the parent value unchanged.
int _isolateEpoch = 0;

int _markEpoch(int value) {
  _isolateEpoch += 1;
  return value;
}

PreparedScans _prepareMark(Map<String, Object?> message) {
  _isolateEpoch += 1;
  return prepareRawScansWorker(message);
}

List<HexCoverageCluster> _hexMark(Map<String, Object?> message) {
  _isolateEpoch += 1;
  return aggregateCoverageHexesWorker(message);
}

void main() {
  test('dispatcher spawns a real isolate under flutter test', () async {
    expect(Platform.environment['FLUTTER_TEST'], 'true');

    final inlineBefore = _isolateEpoch;
    final inline = await runOffUi(_markEpoch, 7, weight: heavyScanCount - 1);
    expect(inline, 7);
    expect(_isolateEpoch, inlineBefore + 1);

    final heavyBefore = _isolateEpoch;
    final heavy = await runOffUi(_markEpoch, 8, weight: heavyScanCount);
    expect(heavy, 8);
    expect(_isolateEpoch, heavyBefore);

    final forcedBefore = _isolateEpoch;
    final forced = await runOffUi(_markEpoch, 9, force: true);
    expect(forced, 9);
    expect(_isolateEpoch, forcedBefore);
  });

  test('prepareRawScans worker matches inline on a heavy payload', () async {
    final scans = _representativeScans();
    expect(scans.length, greaterThanOrEqualTo(heavyScanCount));
    final message = <String, Object?>{
      'scans': scans,
      'connectedRadioId': 'AAAA1111',
      'sanitizeDeadzoneRadios': true,
    };
    final local = prepareRawScans(
      scans,
      connectedRadioId: 'AAAA1111',
      sanitizeDeadzoneRadios: true,
    );

    final direct = await Isolate.run(() => prepareRawScansWorker(message));
    final before = _isolateEpoch;
    final viaDispatcher = await runOffUi(
      _prepareMark,
      message,
      weight: scans.length,
    );
    expect(_isolateEpoch, before);

    _expectSamePrepared(direct, local);
    _expectSamePrepared(viaDispatcher, local);
    final loneDead = viaDispatcher.scans.where(
      (scan) => scan.latitude == 41 && scan.nodeId == null,
    );
    expect(loneDead.single.radioId, isNull);
    expect(loneDead.single.senderName, 'Lone dead');
    expect(viaDispatcher.suppressedRows, greaterThan(0));
    expect(viaDispatcher.suppressedHexes, isNotEmpty);
  });

  test(
    'merge, zone prep, and derived rebuild survive a real isolate',
    () async {
      final workerScans = _representativeScans().take(40).toList();
      final localOnly = <RawScan>[
        RawScan.fromJson(
          workerScans.first.toJson(),
        ).copyWith(senderName: 'Local Name'),
        RawScan(
          nodeId: 'ONLYLOC1',
          latitude: 45,
          longitude: -90,
          rssi: -60,
          timestamp: DateTime.utc(2024, 8, 1),
          senderName: 'Only local',
          radioId: 'BBBB2222',
          downloadedFromWorker: false,
        ),
      ];
      final mergeMessage = <String, Object?>{
        'workerScans': workerScans,
        'localScans': localOnly,
      };
      final mergedLocal = mergeWorkerAndLocalScans(
        workerScans: workerScans,
        localScans: localOnly,
      );
      final merged = await Isolate.run(
        () => mergeWorkerAndLocalScansWorker(mergeMessage),
      );
      expect(merged.preservedLocal, mergedLocal.preservedLocal);
      expect(merged.suppressedRows, mergedLocal.suppressedRows);
      _expectSameScans(merged.scans, mergedLocal.scans);

      final zones = <CoverageZone>[
        _zone('heard', isDeadZone: false, radioId: 'CCCC3333'),
        _zone('heard', isDeadZone: true, radioId: 'DEADBEEF'),
        _zone('other-dead', isDeadZone: true, radioId: 'AAAA1111', lat: 41),
      ];
      final zoneMessage = <String, Object?>{
        'zones': zones,
        'connectedRadioId': 'AAAA1111',
      };
      final zonesLocal = prepareCoverageZones(zones, 'AAAA1111');
      final zonesRemote = await runOffUi(
        prepareCoverageZonesWorker,
        zoneMessage,
        force: true,
      );
      expect(zonesRemote.suppressedRows, zonesLocal.suppressedRows);
      _expectSameZones(zonesRemote.zones, zonesLocal.zones);

      final derivedMessage = <String, Object?>{
        'scans': workerScans,
        'includeZones': true,
      };
      final derivedLocal = buildDerivedScanData(workerScans);
      final derived = await Isolate.run(
        () => buildDerivedScanDataWorker(derivedMessage),
      );
      _expectSameZones(derived.zones, derivedLocal.zones);
      expect(derived.nodes.length, derivedLocal.nodes.length);
      for (var i = 0; i < derived.nodes.length; i++) {
        expect(derived.nodes[i].nodeId, derivedLocal.nodes[i].nodeId);
        expect(derived.nodes[i].name, derivedLocal.nodes[i].name);
        expect(derived.nodes[i].latitude, derivedLocal.nodes[i].latitude);
        expect(derived.nodes[i].longitude, derivedLocal.nodes[i].longitude);
        expect(derived.nodes[i].lastSeen, derivedLocal.nodes[i].lastSeen);
      }
      expect(derived.scanResults.length, derivedLocal.scanResults.length);
      for (var i = 0; i < derived.scanResults.length; i++) {
        expect(
          derived.scanResults[i].nodeId,
          derivedLocal.scanResults[i].nodeId,
        );
        expect(derived.scanResults[i].rssi, derivedLocal.scanResults[i].rssi);
        expect(
          derived.scanResults[i].timestamp,
          derivedLocal.scanResults[i].timestamp,
        );
        expect(
          derived.scanResults[i].senderName,
          derivedLocal.scanResults[i].senderName,
        );
        expect(
          derived.scanResults[i].radioId,
          derivedLocal.scanResults[i].radioId,
        );
      }

      final skipped = await runOffUi(
        buildDerivedScanDataWorker,
        <String, Object?>{'scans': workerScans, 'includeZones': false},
        weight: heavyScanCount,
      );
      expect(skipped.zones, isEmpty);
      expect(skipped.nodes.length, derivedLocal.nodes.length);
      expect(skipped.scanResults.length, derivedLocal.scanResults.length);
    },
  );

  test('scan and coverage parsers and storage codec use real isolates', () async {
    final ndjson = [
      '{"nodeId":"ABCDEF01","latitude":37.1,"longitude":-122.1,"rssi":-70,"snr":4.5,"timestamp":"2024-03-01T00:00:00.000Z","senderName":"Alpha"}',
      'not-json',
      '{"latitude":38,"longitude":-121,"timestamp":"2024-03-02T00:00:00.000Z"}',
    ].join('\n');
    final bytes = Uint8List.fromList(utf8.encode(ndjson));
    final parseMessage = <String, Object?>{
      'bytes': bytes,
      'downloadedFromWorker': true,
    };
    final parsedLocal = parseRawScanBytes(bytes, downloadedFromWorker: true);
    final parsed = await runOffUi(
      parseRawScanBytesWorker,
      parseMessage,
      force: true,
    );
    _expectSameScans(parsed, parsedLocal);
    expect(parsed.every((scan) => scan.downloadedFromWorker), isTrue);

    final coverageJson = jsonEncode([
      {
        'id': 'hex-a',
        'centerLat': 37.2,
        'centerLng': -122.2,
        'radiusMeters': 100,
        'avgRssi': -75,
        'avgSnr': 3,
        'scanCount': 4,
        'lastScanned': '2024-04-01T00:00:00.000Z',
        'isDeadZone': false,
        'polygon': [
          [37.2, -122.2],
          [37.21, -122.2],
          [37.205, -122.19],
        ],
        'radioId': 'ABCDEF01',
      },
    ]);
    final coverageBytes = Uint8List.fromList(utf8.encode(coverageJson));
    final coverage = await Isolate.run(
      () => parseCoverageZoneBytes(coverageBytes),
    );
    _expectSameZones(
      coverage ?? const <CoverageZone>[],
      parseCoverageZoneBytes(coverageBytes) ?? const <CoverageZone>[],
    );

    final scans = _representativeScans();
    final encoded = await runOffUi(
      encodeRawScansForStorage,
      scans,
      weight: scans.length,
    );
    expect(encoded, encodeRawScansForStorage(scans));
    final decoded = await runOffUi(
      decodeStoredRawScansWorker,
      encoded,
      weight: encoded.length,
    );
    _expectSameScans(decoded, decodeStoredRawScans(encoded));
  });

  test('hex aggregation worker matches inline grouping', () async {
    final zones = <CoverageZone>[
      _zone('dead', isDeadZone: true, lat: 8, lng: 8),
      _zone('good', isDeadZone: false, lat: 8, lng: 8, rssi: -95, snr: 1),
      _zone('other', isDeadZone: false, lat: 30, lng: 30, rssi: -110, snr: -5),
    ];
    final message = <String, Object?>{'zones': zones, 'scale': 16};
    final local = aggregateCoverageHexes(zones, scale: 16);
    final before = _isolateEpoch;
    final remote = await runOffUi(_hexMark, message, force: true);
    expect(_isolateEpoch, before);
    final production = await aggregateCoverageHexesOffUi(zones, scale: 16);
    _expectSameClusters(remote, local);
    _expectSameClusters(production, local);
  });

  test(
    'history filter worker keeps the same rows across a real isolate',
    () async {
      final keptAt = DateTime(2024, 6, 15, 23, 30);
      final scans = <ScanResult>[
        _result(id: 'kept', nodeId: 'NODEAAAA', timestamp: keptAt),
        _result(id: 'node', nodeId: 'NODEBBBB', timestamp: keptAt),
        _result(
          id: 'day',
          nodeId: 'NODEAAAA',
          timestamp: DateTime(2024, 6, 16, 23, 30),
        ),
        _result(
          id: 'hour',
          nodeId: 'NODEAAAA',
          timestamp: DateTime(2024, 6, 15, 12),
        ),
        _result(
          id: 'hex',
          nodeId: 'NODEAAAA',
          timestamp: keptAt,
          lat: 40,
          lng: -74,
        ),
      ];
      final message = <String, Object?>{
        'scans': scans,
        'selectedNodeIds': <String>['NODEAAAA'],
        'rangeStart': DateTime(2024, 6, 15),
        'rangeEnd': DateTime(2024, 6, 15),
        'startHour': 22,
        'endHour': 2,
        'selectedHexId': hexKey(37, -122),
      };
      final local = filterHistoryScansOffUi(message);
      final remote = await Isolate.run(() => filterHistoryScansOffUi(message));
      final computed = await compute(filterHistoryScansOffUi, message);
      expect(local.map((scan) => scan.id), ['kept']);
      expect(remote.map((scan) => scan.id), ['kept']);
      expect(computed.map((scan) => scan.id), ['kept']);
      expect(remote.single.senderName, 'Name');
      expect(remote.single.radioId, 'RADIO123');
    },
  );

  test('a large history payload round-trips through a real isolate', () async {
    final scans = _bulkHistory(1800);
    expect(scans.length, greaterThanOrEqualTo(1500));
    expect(scans.length, lessThanOrEqualTo(2000));

    final before = _isolateEpoch;
    final encoded = await runOffUi(
      encodeRawScansForStorage,
      scans,
      weight: scans.length,
    );
    expect(_isolateEpoch, before);
    expect(encoded, encodeRawScansForStorage(scans));

    final decoded = await runOffUi(
      decodeStoredRawScansWorker,
      encoded,
      weight: encoded.length,
    );
    expect(_isolateEpoch, before);
    final decodedLocal = decodeStoredRawScans(encoded);
    expect(decoded.length, decodedLocal.length);
    expect(decoded.length, scans.length);
    expect(decoded.first.nodeId, decodedLocal.first.nodeId);
    expect(decoded.first.senderName, decodedLocal.first.senderName);
    expect(decoded.last.nodeId, decodedLocal.last.nodeId);
    expect(decoded[900].rssi, decodedLocal[900].rssi);
    expect(decoded[900].timestamp, decodedLocal[900].timestamp);

    final message = <String, Object?>{
      'scans': scans,
      'connectedRadioId': 'AAAA1111',
      'sanitizeDeadzoneRadios': false,
    };
    final preparedLocal = prepareRawScans(
      scans,
      connectedRadioId: 'AAAA1111',
      sanitizeDeadzoneRadios: false,
    );
    final prepared = await Isolate.run(() => prepareRawScansWorker(message));
    expect(_isolateEpoch, before);
    expect(prepared.scans.length, preparedLocal.scans.length);
    expect(prepared.scans.length, scans.length);
    expect(prepared.scans[123].nodeId, preparedLocal.scans[123].nodeId);
    expect(prepared.scans[123].senderName, scans[123].senderName);
    expect(prepared.scans[123].radioId, preparedLocal.scans[123].radioId);
    expect(prepared.suppressedRows, preparedLocal.suppressedRows);
  });
}

List<RawScan> _representativeScans() {
  final scans = <RawScan>[];
  for (var i = 0; i < 260; i++) {
    final lat = 37.0 + (i % 20) * 0.2;
    final lng = -122.0 - (i % 15) * 0.2;
    scans.add(
      RawScan(
        observerId: 'OBS${i % 3}',
        nodeId: i.toRadixString(16).padLeft(8, '0'),
        latitude: lat,
        longitude: lng,
        rssi: -40.0 - (i % 50),
        snr: (i % 10) - 2,
        snrIn: 1.25,
        altitude: 10.0 + i,
        timestamp: DateTime.utc(2024, 1, 1).add(Duration(minutes: i)),
        receivedAt: DateTime.utc(2024, 1, 1, 3).add(Duration(minutes: i)),
        senderName: 'Node $i',
        receiverName: 'Radio',
        radioId: i.isEven ? 'AAAA1111' : 'BBBB2222',
        downloadedFromWorker: i.isOdd,
      ),
    );
  }
  scans.add(
    RawScan(
      nodeId: null,
      latitude: 37,
      longitude: -122,
      rssi: null,
      timestamp: DateTime.utc(2024, 2, 2),
      senderName: 'Suppressed dead',
      radioId: 'DEADBEEF',
    ),
  );
  scans.add(
    RawScan(
      nodeId: null,
      latitude: 41,
      longitude: -73,
      rssi: null,
      snr: null,
      altitude: 12,
      timestamp: DateTime.utc(2024, 2, 3),
      receivedAt: DateTime.utc(2024, 2, 3, 1),
      senderName: 'Lone dead',
      receiverName: 'Radio',
      radioId: 'DEADBEEF',
      downloadedFromWorker: true,
    ),
  );
  return scans;
}

List<RawScan> _bulkHistory(int count) {
  final scans = <RawScan>[];
  for (var i = 0; i < count; i++) {
    scans.add(
      RawScan(
        observerId: i.isEven ? 'AAAA1111' : 'BBBB2222',
        nodeId: i.toRadixString(16).padLeft(8, '0'),
        latitude: 37.0 + (i % 50) * 0.01,
        longitude: -122.0 - (i % 40) * 0.01,
        rssi: -40.0 - (i % 50),
        snr: (i % 10) - 2,
        snrIn: 1.25,
        altitude: 10.0 + i,
        timestamp: DateTime.utc(2024, 1, 1).add(Duration(minutes: i)),
        receivedAt: DateTime.utc(2024, 1, 1, 3).add(Duration(minutes: i)),
        senderName: 'Node $i',
        receiverName: 'Radio',
        radioId: i.isEven ? 'AAAA1111' : 'BBBB2222',
        downloadedFromWorker: i.isOdd,
      ),
    );
  }
  return scans;
}

CoverageZone _zone(
  String id, {
  required bool isDeadZone,
  String? radioId,
  double lat = 37,
  double lng = -122,
  double? rssi = -80,
  double? snr = 5,
}) {
  return CoverageZone(
    id: id,
    centerLat: lat,
    centerLng: lng,
    radiusMeters: 100,
    avgRssi: isDeadZone ? null : rssi,
    avgSnr: isDeadZone ? null : snr,
    scanCount: isDeadZone ? 1 : 3,
    lastScanned: DateTime.utc(2024, 5, 1),
    isDeadZone: isDeadZone,
    polygon: hexVertices(lat, lng),
    radioId: radioId,
  );
}

ScanResult _result({
  required String id,
  required String nodeId,
  required DateTime timestamp,
  double lat = 37,
  double lng = -122,
}) {
  return ScanResult(
    id: id,
    observerId: 'obs',
    nodeId: nodeId,
    rssi: -80,
    snr: 1,
    snrIn: 0.5,
    latitude: lat,
    longitude: lng,
    altitude: 9,
    timestamp: timestamp,
    senderName: 'Name',
    receiverName: 'Recv',
    radioId: 'RADIO123',
  );
}

void _expectSamePrepared(PreparedScans actual, PreparedScans expected) {
  expect(actual.changed, expected.changed);
  expect(actual.suppressedRows, expected.suppressedRows);
  expect(actual.suppressedHexes, expected.suppressedHexes);
  _expectSameScans(actual.scans, expected.scans);
}

void _expectSameScans(List<RawScan> actual, List<RawScan> expected) {
  expect(actual.length, expected.length);
  for (var i = 0; i < actual.length; i++) {
    expect(actual[i].toJson(), expected[i].toJson());
  }
}

void _expectSameZones(List<CoverageZone> actual, List<CoverageZone> expected) {
  expect(actual.length, expected.length);
  for (var i = 0; i < actual.length; i++) {
    expect(actual[i].id, expected[i].id);
    expect(actual[i].isDeadZone, expected[i].isDeadZone);
    expect(actual[i].avgRssi, expected[i].avgRssi);
    expect(actual[i].avgSnr, expected[i].avgSnr);
    expect(actual[i].scanCount, expected[i].scanCount);
    expect(actual[i].radioId, expected[i].radioId);
    expect(actual[i].centerLat, expected[i].centerLat);
    expect(actual[i].centerLng, expected[i].centerLng);
    expect(actual[i].lastScanned, expected[i].lastScanned);
    expect(actual[i].polygon, expected[i].polygon);
  }
}

void _expectSameClusters(
  List<HexCoverageCluster> actual,
  List<HexCoverageCluster> expected,
) {
  expect(actual.length, expected.length);
  for (var i = 0; i < actual.length; i++) {
    expect(actual[i].hitZoneId, expected[i].hitZoneId);
    expect(actual[i].childCount, expected[i].childCount);
    expect(actual[i].coveredCount, expected[i].coveredCount);
    expect(actual[i].scale, expected[i].scale);
    expect(actual[i].isDeadZone, expected[i].isDeadZone);
    expect(actual[i].memberZoneIds, expected[i].memberZoneIds);
    expect(actual[i].points, expected[i].points);
    expect(actual[i].avgRssi, expected[i].avgRssi);
    expect(actual[i].avgSnr, expected[i].avgSnr);
  }
}
