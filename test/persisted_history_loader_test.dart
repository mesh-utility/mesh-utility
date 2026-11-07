import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/persisted_history_loader_io.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

RawScan _scan({
  String? nodeId,
  double lat = 37.0,
  double lng = -122.0,
  double? rssi = -80,
  DateTime? timestamp,
}) {
  return RawScan(
    nodeId: nodeId,
    latitude: lat,
    longitude: lng,
    rssi: rssi,
    timestamp: timestamp ?? DateTime.utc(2024, 3, 3),
  );
}

void main() {
  test(
    'legacy cache keeps successes and suppresses same-hex deadzones',
    () async {
      final dir = await Directory.systemTemp.createTemp('mesh-history-');
      final databasePath = dir.path;
      try {
        final success = _scan(nodeId: 'ABCDEF01');
        final otherSuccess = _scan(
          nodeId: '12345678',
          lat: 41.0,
          lng: -73.0,
          rssi: -70,
          timestamp: DateTime.utc(2024, 3, 4),
        );
        final deadInSuccessHex = _scan(nodeId: null, rssi: null);
        final loneDead = _scan(
          nodeId: null,
          rssi: null,
          lat: 40.0,
          lng: -74.0,
          timestamp: DateTime.utc(2024, 3, 5),
        );
        final db = await ReaxDB.simple(databasePath);
        await db.put(rawScansStorageKey, <Map<String, dynamic>>[
          success.toJson(),
          deadInSuccessHex.toJson(),
          otherSuccess.toJson(),
          loneDead.toJson(),
        ]);
        await db.close();

        final loaded = await loadPersistedHistory(databasePath);

        expect(loaded.suppressedRows, 1);
        expect(loaded.persistedChanges, isTrue);
        expect(loaded.scans, hasLength(3));
        expect(loaded.scans.map((scan) => scan.nodeId).toSet(), <String?>{
          'ABCDEF01',
          '12345678',
          null,
        });
        expect(
          loaded.scans.where(
            (scan) => scan.latitude == 37.0 && scan.nodeId == null,
          ),
          isEmpty,
        );
        expect(
          loaded.scans.where((scan) => scan.latitude == 40.0),
          hasLength(1),
        );
        // Dead-like rows stay in the raw cache and are omitted from results.
        expect(loaded.scanResults, hasLength(2));
        expect(
          loaded.scanResults.map((scan) => scan.nodeId).toSet(),
          {'ABCDEF01', '12345678'},
        );
      } finally {
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
      }
    },
  );
}
