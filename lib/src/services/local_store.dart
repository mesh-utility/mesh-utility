import 'package:flutter/foundation.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/off_ui.dart';
import 'package:mesh_utility/src/services/reax_database.dart';

class LocalStore {
  Future<List<RawScan>> loadRawScans() async {
    final db = await ReaxDatabase.instance();
    final raw = await db.get(rawScansStorageKey);
    if (raw == null) return const <RawScan>[];
    if (raw is! String && raw is! List) return const <RawScan>[];
    final stored = raw;
    return runOffUi(
      () => decodeStoredRawScans(stored),
      weight: raw is String ? raw.length : (raw as List).length,
    );
  }

  Future<void> saveRawScans(List<RawScan> scans) async {
    final db = await ReaxDatabase.instance();
    if (!kIsWeb && scans.length >= heavyScanCount) {
      final encoded = await runOffUi(
        () => encodeRawScansForStorage(scans),
        weight: scans.length,
      );
      await db.put(rawScansStorageKey, encoded);
      return;
    }
    final payload = compactRawScansForPersistence(
      scans,
    ).map((scan) => scan.toJson()).toList(growable: false);
    await db.put(rawScansStorageKey, payload);
  }

  Future<void> clearRawScans() async {
    final db = await ReaxDatabase.instance();
    await db.put(rawScansStorageKey, <Map<String, dynamic>>[]);
  }
}
