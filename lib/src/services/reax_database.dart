import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

class ReaxDatabase {
  static SimpleReaxDB? _db;
  static Future<SimpleReaxDB>? _opening;

  static Future<SimpleReaxDB> instance() {
    if (_db != null) return Future.value(_db);

    if (_opening != null) {
      return _opening!;
    }

    _opening = () async {
      try {
        final baseDir = await getApplicationSupportDirectory();
        final dbPath = '${baseDir.path}${Platform.pathSeparator}mesh_utility';
        final value = await ReaxDB.simple(dbPath);
        _db = value;
        return value;
      } catch (_) {
        final value = await ReaxDB.simple('mesh_utility');
        _db = value;
        return value;
      }
    }();

    return _opening!;
  }
}
