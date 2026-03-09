import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/reax_database.dart';

class LocalStore {
  static const _rawScansKey = 'scans:raw';

  Future<List<RawScan>> loadRawScans() async {
    final db = await ReaxDatabase.instance();
    final raw = await db.get(_rawScansKey);
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((entry) => RawScan.fromJson(entry.cast<String, dynamic>()))
        .toList();
  }

  Future<void> saveRawScans(List<RawScan> scans) async {
    final db = await ReaxDatabase.instance();
    final payload = scans.map((scan) => scan.toJson()).toList();
    await db.put(_rawScansKey, payload);
  }

  Future<void> clearRawScans() async {
    final db = await ReaxDatabase.instance();
    await db.put(_rawScansKey, <Map<String, dynamic>>[]);
  }
}
