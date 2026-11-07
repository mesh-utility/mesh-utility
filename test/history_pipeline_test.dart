import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';

RawScan _scan({
  String? nodeId,
  String? observerId,
  String? radioId,
  double lat = 37.0,
  double lng = -122.0,
  double? rssi = -80,
  DateTime? timestamp,
}) {
  return RawScan(
    nodeId: nodeId,
    observerId: observerId,
    radioId: radioId,
    latitude: lat,
    longitude: lng,
    rssi: rssi,
    timestamp: timestamp ?? DateTime.utc(2024, 1, 1),
  );
}

void main() {
  group('prepareRawScans', () {
    test('empty input drops nothing', () {
      final prepared = prepareRawScans(const <RawScan>[]);
      expect(prepared.changed, isFalse);
      expect(prepared.suppressedRows, 0);
      expect(prepared.scans, isEmpty);
      expect(prepared.suppressedHexes, isEmpty);
    });

    test('keeps successes and drops deadzones only in successful hexes', () {
      final success = _scan(nodeId: 'ABCDEF01');
      final deadInSuccessHex = _scan(nodeId: null, rssi: null);
      final loneDead = _scan(nodeId: null, rssi: null, lat: 40.0, lng: -74.0);
      final otherSuccess = _scan(
        nodeId: '12345678',
        lat: 41.0,
        lng: -73.0,
        rssi: -70,
      );

      final prepared = prepareRawScans([
        success,
        deadInSuccessHex,
        loneDead,
        otherSuccess,
      ]);

      expect(prepared.suppressedRows, 1);
      expect(prepared.scans, hasLength(3));
      expect(
        prepared.scans.map((scan) => scan.nodeId),
        containsAll(<String?>['ABCDEF01', '12345678', null]),
      );
      expect(
        prepared.scans.where(
          (scan) => scan.latitude == 37.0 && (scan.nodeId ?? '').isEmpty,
        ),
        isEmpty,
      );
      expect(
        prepared.scans.where((scan) => scan.latitude == 40.0),
        hasLength(1),
      );
    });

    test('unchanged safe ids keep the same instance', () {
      final scan = _scan(
        nodeId: 'ABCDEF01',
        observerId: '1234ABCD',
        radioId: '1234ABCD',
      );
      final prepared = prepareRawScans([scan]);
      expect(prepared.changed, isFalse);
      expect(prepared.suppressedRows, 0);
      expect(identical(prepared.scans.single, scan), isTrue);
    });
  });

  group('decodeStoredRawScans', () {
    test('accepts a legacy list and a JSON string without dropping rows', () {
      final first = _scan(nodeId: 'ABCDEF01', radioId: '1234ABCD');
      final second = _scan(
        nodeId: '12345678',
        lat: 40.0,
        lng: -74.0,
        rssi: -90,
        timestamp: DateTime.utc(2024, 2, 2),
      );
      final rows = <dynamic>[first.toJson(), second.toJson(), 'bad-row', 4];

      final fromList = decodeStoredRawScans(rows);
      final fromString = decodeStoredRawScans(jsonEncode(rows));

      expect(fromList, hasLength(2));
      expect(fromString, hasLength(2));
      expect(fromList.map((scan) => scan.nodeId), ['ABCDEF01', '12345678']);
      expect(fromString.map((scan) => scan.nodeId), ['ABCDEF01', '12345678']);
      expect(fromString[1].latitude, 40.0);
      expect(fromString[1].rssi, -90);
    });
  });
}
