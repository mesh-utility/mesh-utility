import 'package:mesh_utility/src/services/reax_database_backend_base.dart';
import 'package:mesh_utility/src/services/reax_database_backend_stub.dart'
    if (dart.library.io) 'package:mesh_utility/src/services/reax_database_backend_io.dart'
    if (dart.library.js_interop) 'package:mesh_utility/src/services/reax_database_backend_web.dart'
    as backend;

class ReaxDatabase {
  static AppKvDatabase? _db;
  static Future<AppKvDatabase>? _opening;

  static Future<AppKvDatabase> instance() {
    if (_db != null) return Future.value(_db);
    if (_opening != null) return _opening!;

    _opening = () async {
      final value = await backend.openAppKvDatabase();
      _db = value;
      return value;
    }();
    return _opening!;
  }
}
