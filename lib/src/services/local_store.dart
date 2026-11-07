import 'package:flutter/foundation.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/mesh_stage_log.dart';
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
      decodeStoredRawScansWorker,
      stored,
      weight: raw is String ? raw.length : (raw as List).length,
    );
  }

  Future<void> saveRawScans(List<RawScan> scans) async {
    final db = await ReaxDatabase.instance();
    final watch = Stopwatch()..start();
    if (!kIsWeb && scans.length >= heavyScanCount) {
      meshStageStart('history_encode', count: scans.length);
      final encoded = await runOffUi(
        encodeRawScansForStorage,
        scans,
        weight: scans.length,
      );
      meshStageEnd(
        'history_encode',
        count: scans.length,
        ms: watch.elapsedMilliseconds,
        n2: encoded.length,
      );
      watch.reset();
      meshStageStart('history_db_put', count: encoded.length);
      await db.put(rawScansStorageKey, encoded);
      meshStageEnd(
        'history_db_put',
        count: encoded.length,
        ms: watch.elapsedMilliseconds,
      );
      return;
    }
    meshStageStart('history_save_inline', count: scans.length);
    final payload = compactRawScansForPersistence(
      scans,
    ).map((scan) => scan.toJson()).toList(growable: false);
    await db.put(rawScansStorageKey, payload);
    meshStageEnd(
      'history_save_inline',
      count: scans.length,
      ms: watch.elapsedMilliseconds,
      n2: payload.length,
    );
  }

  Future<void> clearRawScans() async {
    final db = await ReaxDatabase.instance();
    await db.put(rawScansStorageKey, <Map<String, dynamic>>[]);
  }
}
