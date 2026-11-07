import 'dart:async';

import 'package:mesh_utility/src/services/reax_database_backend_base.dart';
import 'package:mesh_utility/src/services/reax_database_backend_stub.dart'
    if (dart.library.io) 'package:mesh_utility/src/services/reax_database_backend_io.dart'
    if (dart.library.js_interop) 'package:mesh_utility/src/services/reax_database_backend_web.dart'
    as backend;

class ReaxDatabase {
  static AppKvDatabase? _db;
  static Future<AppKvDatabase>? _opening;
  static Completer<AppKvDatabase>? _exclusive;

  static Future<AppKvDatabase> instance() {
    if (_db != null) return Future.value(_db);
    if (_opening != null) return _opening!;

    _opening = () async {
      final value = await backend.openAppKvDatabase();
      _db = value;
      _opening = null;
      return value;
    }();
    return _opening!;
  }

  /// Closes the open handle so a background isolate can read the same files.
  /// [instance] waits until [endExclusiveDatabaseAccess] reopens it.
  static Future<void> beginExclusiveDatabaseAccess() async {
    if (_exclusive != null) {
      throw StateError('Database exclusive access already held');
    }
    final existing = _db;
    final gate = Completer<AppKvDatabase>();
    _exclusive = gate;
    _db = null;
    _opening = gate.future;
    try {
      if (existing != null) await existing.close();
    } catch (error, stack) {
      _db = null;
      _opening = null;
      _exclusive = null;
      if (!gate.isCompleted) gate.completeError(error, stack);
      rethrow;
    }
  }

  static Future<void> endExclusiveDatabaseAccess() async {
    final gate = _exclusive;
    try {
      final db = await backend.openAppKvDatabase();
      _db = db;
      _opening = null;
      _exclusive = null;
      if (gate != null && !gate.isCompleted) gate.complete(db);
    } catch (error, stack) {
      _db = null;
      _opening = null;
      _exclusive = null;
      if (gate != null && !gate.isCompleted) gate.completeError(error, stack);
      rethrow;
    }
  }
}
