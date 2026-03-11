// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:convert';
import 'dart:html' as html;

import 'package:mesh_utility/src/services/reax_database_backend_base.dart';

Future<AppKvDatabase> openAppKvDatabase() async {
  return _WebLocalStorageKvDatabase();
}

class _WebLocalStorageKvDatabase implements AppKvDatabase {
  static const String _prefix = 'mesh_utility:';

  @override
  Future<dynamic> get(String key) async {
    final raw = html.window.localStorage['$_prefix$key'];
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> put(String key, dynamic value) async {
    html.window.localStorage['$_prefix$key'] = jsonEncode(value);
  }
}
