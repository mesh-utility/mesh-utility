import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

import 'package:mesh_utility/src/services/reax_database_backend_base.dart';

Future<AppKvDatabase> openAppKvDatabase() async {
  try {
    final baseDir = await getApplicationSupportDirectory();
    final dbPath = '${baseDir.path}${Platform.pathSeparator}mesh_utility';
    final db = await ReaxDB.simple(dbPath);
    return _ReaxKvDatabase(db);
  } catch (_) {
    final db = await ReaxDB.simple('mesh_utility');
    return _ReaxKvDatabase(db);
  }
}

class _ReaxKvDatabase implements AppKvDatabase {
  _ReaxKvDatabase(this._db);

  final SimpleReaxDB _db;

  @override
  Future<dynamic> get(String key) => _db.get(key);

  @override
  Future<void> put(String key, dynamic value) => _db.put(key, value);
}
