abstract class AppKvDatabase {
  Future<dynamic> get(String key);
  Future<void> put(String key, dynamic value);
}
