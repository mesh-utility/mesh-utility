import 'package:mesh_utility/src/services/reax_database.dart';

/// Last device fix used as the radius-cache center across launches.
class LastKnownFix {
  const LastKnownFix({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

class LastKnownFixStore {
  static const storageKey = 'device:lastFix';

  Future<LastKnownFix?> load() async {
    final db = await ReaxDatabase.instance();
    final raw = await db.get(storageKey);
    if (raw is! Map) return null;
    final lat = _asDouble(raw['lat'] ?? raw['latitude']);
    final lng = _asDouble(raw['lng'] ?? raw['longitude']);
    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return LastKnownFix(latitude: lat, longitude: lng);
  }

  Future<void> save(double latitude, double longitude) async {
    final db = await ReaxDatabase.instance();
    await db.put(storageKey, <String, Object>{
      'lat': latitude,
      'lng': longitude,
    });
  }

  double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
