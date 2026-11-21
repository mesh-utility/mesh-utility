import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/pages/map_page.dart';
import 'package:mesh_utility/src/services/grid.dart';

ScanResult _scan({
  required String nodeId,
  required double latitude,
  required double longitude,
}) {
  return ScanResult(
    id: '$nodeId@$latitude,$longitude',
    observerId: 'OBS',
    nodeId: nodeId,
    rssi: -80,
    snr: 5,
    snrIn: 1,
    latitude: latitude,
    longitude: longitude,
    altitude: 0,
    timestamp: DateTime.utc(2026, 1, 1),
    senderName: null,
    receiverName: null,
    radioId: null,
  );
}

void main() {
  const lat = 40.79;
  const lng = -77.86;

  test('matches either zone-id form and honors node filters', () {
    final indexId = hexIndexId(lat, lng);
    final keyId = hexKey(lat, lng);
    expect(indexId, isNot(keyId));
    expect(coverageZoneIdsForPoint(lat, lng), {indexId, keyId});

    final scans = <ScanResult>[
      _scan(nodeId: 'abcdef012345', latitude: lat, longitude: lng),
      _scan(nodeId: 'ABCDEF012345', latitude: lat, longitude: lng),
      _scan(nodeId: '   ', latitude: lat, longitude: lng),
      _scan(nodeId: '11223344', latitude: 0, longitude: 0),
      _scan(nodeId: '99aabbcc', latitude: lat, longitude: lng),
    ];

    expect(
      scopedNodeIdsFromScans(scans: scans, filteredZoneIds: <String>{indexId}),
      {'ABCDEF01', '99AABBCC'},
    );
    expect(
      scopedNodeIdsFromScans(scans: scans, filteredZoneIds: <String>{keyId}),
      {'ABCDEF01', '99AABBCC'},
    );
    expect(
      scopedNodeIdsFromScans(
        scans: scans,
        filteredZoneIds: <String>{'not-a-cell'},
      ),
      isEmpty,
    );
    expect(
      scopedNodeIdsFromScans(
        scans: scans,
        filteredZoneIds: <String>{indexId},
      ).contains('11223344'),
      isFalse,
    );
    expect(
      scopedNodeIdsFromScans(
        scans: scans,
        filteredZoneIds: <String>{indexId, keyId},
        nodeFilters: {'ABCDEF01'},
      ),
      {'ABCDEF01'},
    );
    expect(
      scopedNodeIdsFromScans(
        scans: const <ScanResult>[],
        filteredZoneIds: <String>{indexId},
      ),
      isEmpty,
    );
  });

  test('stays fast when many zone ids do not contain the point', () {
    final indexId = hexIndexId(lat, lng);
    final zoneIds = <String>{indexId};
    for (var i = 0; i < 14000; i++) {
      zoneIds.add('hex:9:$i');
    }
    final scans = List<ScanResult>.generate(8400, (i) {
      if (i == 0) {
        return _scan(nodeId: 'ABCDEF012345', latitude: lat, longitude: lng);
      }
      return _scan(
        nodeId: 'BEEF${(i % 1000).toRadixString(16).padLeft(4, '0')}',
        latitude: 12 + (i % 40) * 0.05,
        longitude: 12 + (i % 25) * 0.05,
      );
    });

    final watch = Stopwatch()..start();
    final heard = scopedNodeIdsFromScans(
      scans: scans,
      filteredZoneIds: zoneIds,
    );
    watch.stop();

    expect(heard.contains('ABCDEF01'), isTrue);
    // The old Set.intersection walked all 14k zone ids per scan (~4s).
    expect(watch.elapsedMilliseconds, lessThan(1000));
  });
}
