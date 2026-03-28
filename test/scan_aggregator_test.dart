import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/scan_aggregator.dart';

RawScan _scan({
  String? nodeId,
  double lat = 37.7749,
  double lng = -122.4194,
  double? rssi = -80.0,
  double? snr,
  String? radioId,
  String? senderName,
  DateTime? timestamp,
}) {
  return RawScan(
    nodeId: nodeId,
    latitude: lat,
    longitude: lng,
    rssi: rssi,
    snr: snr,
    radioId: radioId,
    senderName: senderName,
    timestamp: timestamp ?? DateTime(2024, 1, 1),
  );
}

void main() {
  group('aggregateScansToZones', () {
    test('empty input returns empty list', () {
      expect(aggregateScansToZones([]), isEmpty);
    });

    test('single scan produces one zone', () {
      final zones = aggregateScansToZones([_scan(nodeId: 'abc123')]);
      expect(zones.length, equals(1));
    });

    test('zone is marked dead when all scans have no nodeId', () {
      final zones = aggregateScansToZones([_scan(nodeId: null, rssi: null)]);
      expect(zones.first.isDeadZone, isTrue);
    });

    test('zone is not dead when at least one scan has nodeId and rssi', () {
      final zones = aggregateScansToZones([
        _scan(nodeId: null, rssi: null),
        _scan(nodeId: 'abc', rssi: -75.0),
      ]);
      expect(zones.first.isDeadZone, isFalse);
    });

    test('best RSSI is selected from multiple scans in same hex', () {
      final zones = aggregateScansToZones([
        _scan(nodeId: 'a', rssi: -90.0),
        _scan(nodeId: 'b', rssi: -70.0),
        _scan(nodeId: 'c', rssi: -80.0),
      ]);
      expect(zones.first.avgRssi, closeTo(-70.0, 0.01));
    });

    test('scans in different hexes produce separate zones', () {
      final zones = aggregateScansToZones([
        _scan(nodeId: 'a', lat: 37.7749, lng: -122.4194),
        _scan(nodeId: 'b', lat: 40.7128, lng: -74.0060),
      ]);
      expect(zones.length, equals(2));
    });

    test('scanCount reflects all scans in the hex', () {
      final zones = aggregateScansToZones([
        _scan(nodeId: 'a', rssi: -80.0),
        _scan(nodeId: 'b', rssi: -85.0),
        _scan(nodeId: null, rssi: null),
      ]);
      expect(zones.first.scanCount, equals(3));
    });

    test('zone polygon has exactly 6 vertices', () {
      final zones = aggregateScansToZones([_scan(nodeId: 'a')]);
      expect(zones.first.polygon.length, equals(6));
    });
  });

  group('extractNodes', () {
    test('empty input returns empty list', () {
      expect(extractNodes([]), isEmpty);
    });

    test('scans without nodeId are ignored', () {
      final nodes = extractNodes([_scan(nodeId: null)]);
      expect(nodes, isEmpty);
    });

    test('unique nodeIds produce unique nodes', () {
      final nodes = extractNodes([
        _scan(nodeId: 'node1'),
        _scan(nodeId: 'node2'),
      ]);
      expect(nodes.length, equals(2));
    });

    test('duplicate nodeId is deduplicated', () {
      final nodes = extractNodes([
        _scan(nodeId: 'node1'),
        _scan(nodeId: 'node1'),
      ]);
      expect(nodes.length, equals(1));
    });

    test('most recent timestamp wins for same nodeId', () {
      final older = DateTime(2024, 1, 1);
      final newer = DateTime(2024, 6, 1);
      final nodes = extractNodes([
        _scan(nodeId: 'n1', timestamp: older),
        _scan(nodeId: 'n1', timestamp: newer),
      ]);
      expect(nodes.first.lastSeen, equals(newer));
    });

    test('non-placeholder name is preferred over null', () {
      final nodes = extractNodes([
        _scan(nodeId: 'n1', senderName: null),
        _scan(nodeId: 'n1', senderName: 'Radio Alpha'),
      ]);
      expect(nodes.first.name, equals('Radio Alpha'));
    });

    test('placeholder name (Unknown (id)) is not used', () {
      final nodes = extractNodes([
        _scan(nodeId: 'abc', senderName: 'Unknown (abc)'),
      ]);
      expect(nodes.first.name, isNull);
    });
  });

  group('convertToScanResults', () {
    test('empty input returns empty list', () {
      expect(convertToScanResults([]), isEmpty);
    });

    test('scans without nodeId are excluded', () {
      final results = convertToScanResults([_scan(nodeId: null)]);
      expect(results, isEmpty);
    });

    test('scans without rssi are excluded', () {
      final results = convertToScanResults([_scan(nodeId: 'a', rssi: null)]);
      expect(results, isEmpty);
    });

    test('valid scan is included with correct rssi', () {
      final results = convertToScanResults([
        _scan(nodeId: 'node1', rssi: -75.0),
      ]);
      expect(results.length, equals(1));
      expect(results.first.rssi, closeTo(-75.0, 0.01));
    });

    test('results preserve snr when present', () {
      final results = convertToScanResults([
        _scan(nodeId: 'n', rssi: -80.0, snr: 5.5),
      ]);
      expect(results.first.snr, closeTo(5.5, 0.01));
    });
  });
}
