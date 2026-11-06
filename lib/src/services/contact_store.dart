import 'package:mesh_utility/src/models/local_contact.dart';
import 'package:mesh_utility/src/platform/local_contacts_supported.dart';
import 'package:mesh_utility/src/services/reax_database.dart';
import 'package:mesh_utility/src/services/settings_store.dart';

Map<String, dynamic> _safeMap(Map<dynamic, dynamic> m) {
  return {for (final e in m.entries) e.key.toString(): e.value};
}

/// On-device master contact book + per-radio settings, keyed by radio mesh id.
///
/// No-ops persistence when [localContactsSupported] is false (web / other).
class ContactStore {
  static String contactsKey(String radioId) =>
      'contacts:radio:${radioId.trim().toUpperCase()}';

  static String settingsKey(String radioId) =>
      'settings:radio:${radioId.trim().toUpperCase()}';

  /// Load contacts for [radioId]. Empty on unsupported platforms.
  Future<Map<String, LocalContact>> loadContacts(String radioId) async {
    final id = radioId.trim().toUpperCase();
    if (!localContactsSupported || id.isEmpty) return {};
    final db = await ReaxDatabase.instance();
    final raw = await db.get(contactsKey(id));
    if (raw is! List) return {};
    final out = <String, LocalContact>{};
    for (final entry in raw.whereType<Map>()) {
      final c = LocalContact.fromJson(_safeMap(entry));
      if (c.publicKeyPrefix.isEmpty) continue;
      out[c.publicKeyPrefix] = c;
    }
    return out;
  }

  Future<void> saveContacts(
    String radioId,
    Map<String, LocalContact> contacts,
  ) async {
    final id = radioId.trim().toUpperCase();
    if (!localContactsSupported || id.isEmpty) return;
    final db = await ReaxDatabase.instance();
    final payload =
        contacts.values.map((c) => c.toJson()).toList(growable: false);
    await db.put(contactsKey(id), payload);
  }

  /// Merge [incoming] into the stored book for [radioId] and persist.
  Future<Map<String, LocalContact>> mergeContacts(
    String radioId,
    Iterable<LocalContact> incoming,
  ) async {
    final id = radioId.trim().toUpperCase();
    if (id.isEmpty) return {};
    final current = await loadContacts(id);
    for (final c in incoming) {
      final prefix = c.publicKeyPrefix.trim().toUpperCase();
      if (prefix.isEmpty) continue;
      final existing = current[prefix];
      current[prefix] =
          existing == null ? c.copyWith(publicKeyPrefix: prefix) : mergeLocalContact(existing, c.copyWith(publicKeyPrefix: prefix));
    }
    await saveContacts(id, current);
    return current;
  }

  Future<AppSettings?> loadRadioSettings(String radioId) async {
    final id = radioId.trim().toUpperCase();
    if (!localContactsSupported || id.isEmpty) return null;
    final db = await ReaxDatabase.instance();
    final raw = await db.get(settingsKey(id));
    if (raw is! Map) return null;
    try {
      return AppSettings.fromJson(_safeMap(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveRadioSettings(String radioId, AppSettings settings) async {
    final id = radioId.trim().toUpperCase();
    if (!localContactsSupported || id.isEmpty) return;
    final db = await ReaxDatabase.instance();
    await db.put(settingsKey(id), settings.toJson());
  }
}
