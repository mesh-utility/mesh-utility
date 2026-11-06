import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/reax_database.dart';
import 'package:mesh_utility/src/services/scan_data_utils.dart';

Map<String, dynamic> _safeMap(Map<dynamic, dynamic> m) {
  return {for (final e in m.entries) e.key.toString(): e.value};
}

class LocalStore {
  static const _rawScansKey = 'scans:raw';

  Future<List<RawScan>> loadRawScans() async {
    final db = await ReaxDatabase.instance();
    final raw = await db.get(_rawScansKey);
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((entry) => RawScan.fromJson(_safeMap(entry)))
        .toList();
  }

  Future<void> saveRawScans(List<RawScan> scans) async {
    final db = await ReaxDatabase.instance();
    final payload = _compactForPersistence(
      scans,
    ).map((scan) => scan.toJson()).toList(growable: false);
    await db.put(_rawScansKey, payload);
  }

  Future<void> clearRawScans() async {
    final db = await ReaxDatabase.instance();
    await db.put(_rawScansKey, <Map<String, dynamic>>[]);
  }

  List<RawScan> _compactForPersistence(List<RawScan> scans) {
    if (scans.isEmpty) return const [];

    final sorted = scans.toList(growable: false)
      ..sort((a, b) => b.effectiveTimestamp.compareTo(a.effectiveTimestamp));

    final seen = <String>{};
    final kept = <RawScan>[];

    for (final scan in sorted) {
      final identity = scanIdentity(scan);
      if (!seen.add(identity)) continue;
      kept.add(scan);
    }

    return kept;
  }
}
