import 'package:mesh_utility/src/services/reax_database_backend_base.dart';

Future<AppKvDatabase> openAppKvDatabase() async {
  return _InMemoryKvDatabase();
}

class _InMemoryKvDatabase implements AppKvDatabase {
  final Map<String, dynamic> _store = <String, dynamic>{};

  @override
  Future<dynamic> get(String key) async => _store[key];

  @override
  Future<void> put(String key, dynamic value) async {
    _store[key] = value;
  }
}
