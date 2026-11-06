// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:convert';
import 'dart:html' as html;

import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/reax_database_backend_base.dart';

Future<AppKvDatabase> openAppKvDatabase() async {
  final idbFactory = html.window.indexedDB;
  if (idbFactory == null) {
    AppDebugLogService.instance.warn(
      'storage',
      'IndexedDB unavailable on web; falling back to localStorage',
    );
    return _WebLocalStorageKvDatabase();
  }

  try {
    final db = await idbFactory.open(
      _WebIndexedDbKvDatabase.dbName,
      version: _WebIndexedDbKvDatabase.dbVersion,
      onUpgradeNeeded: (event) {
        final dynamic request = event.target;
        final database = request.result;
        final storeNames = database.objectStoreNames ?? const <String>[];
        if (!storeNames.contains(_WebIndexedDbKvDatabase.storeName)) {
          database.createObjectStore(_WebIndexedDbKvDatabase.storeName);
        }
      },
    );

    final database = _WebIndexedDbKvDatabase(db);
    await database.migrateLegacyLocalStorage();
    return database;
  } catch (error) {
    AppDebugLogService.instance.warn(
      'storage',
      'IndexedDB open failed on web; falling back to localStorage: $error',
    );
    return _WebLocalStorageKvDatabase();
  }
}

class _WebIndexedDbKvDatabase implements AppKvDatabase {
  _WebIndexedDbKvDatabase(this._db);

  static const String dbName = 'mesh_utility_kv';
  static const int dbVersion = 1;
  static const String storeName = 'kv';
  static const String _prefix = 'mesh_utility:';

  final dynamic _db;
  final AppDebugLogService _debugLog = AppDebugLogService.instance;

  Future<void> migrateLegacyLocalStorage() async {
    final legacyKeys = html.window.localStorage.keys
        .where((key) => key.startsWith(_prefix))
        .toList(growable: false);
    if (legacyKeys.isEmpty) return;

    _debugLog.warn(
      'storage',
      'Migrating ${legacyKeys.length} legacy web storage entr${legacyKeys.length == 1 ? 'y' : 'ies'} to IndexedDB',
    );

    for (final storageKey in legacyKeys) {
      final rawValue = html.window.localStorage[storageKey];
      if (rawValue == null) continue;
      final key = storageKey.substring(_prefix.length);
      final existingValue = await _readRawValue(key);
      if (existingValue != null) {
        html.window.localStorage.remove(storageKey);
        continue;
      }
      await _writeRawValue(key, rawValue);
      html.window.localStorage.remove(storageKey);
    }
  }

  @override
  Future<dynamic> get(String key) async {
    final raw = await _readRawValue(key) ?? await _readLegacyAndMigrate(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (error) {
      _debugLog.warn(
        'storage',
        'Failed to decode IndexedDB value key=$key: $error',
      );
      return null;
    }
  }

  @override
  Future<void> put(String key, dynamic value) async {
    await _writeRawValue(key, jsonEncode(value));
    html.window.localStorage.remove('$_prefix$key');
  }

  Future<String?> _readLegacyAndMigrate(String key) async {
    final storageKey = '$_prefix$key';
    final raw = html.window.localStorage[storageKey];
    if (raw == null) return null;
    _debugLog.warn(
      'storage',
      'Migrating legacy web storage key=$key from localStorage to IndexedDB',
    );
    try {
      await _writeRawValue(key, raw);
      html.window.localStorage.remove(storageKey);
      return raw;
    } catch (error) {
      _debugLog.warn('storage', 'Failed migrating legacy key=$key: $error');
      return raw;
    }
  }

  Future<String?> _readRawValue(String key) async {
    final transaction = _db.transaction(storeName, 'readonly');
    final store = transaction.objectStore(storeName);
    final value = await store.getObject(key);
    await transaction.completed;
    if (value == null) return null;
    return value.toString();
  }

  Future<void> _writeRawValue(String key, String value) async {
    final transaction = _db.transaction(storeName, 'readwrite');
    final store = transaction.objectStore(storeName);
    await store.put(value, key);
    await transaction.completed;
  }
}

class _WebLocalStorageKvDatabase implements AppKvDatabase {
  static const String _prefix = 'mesh_utility:';

  final Map<String, String> _memoryFallback = <String, String>{};
  final AppDebugLogService _debugLog = AppDebugLogService.instance;

  @override
  Future<dynamic> get(String key) async {
    final raw =
        _memoryFallback[key] ?? html.window.localStorage['$_prefix$key'];
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> put(String key, dynamic value) async {
    final encoded = jsonEncode(value);
    _memoryFallback[key] = encoded;
    try {
      html.window.localStorage['$_prefix$key'] = encoded;
    } catch (error) {
      _debugLog.warn(
        'storage',
        'Web localStorage write failed for key=$key; keeping in-memory fallback only: $error',
      );
    }
  }
}
