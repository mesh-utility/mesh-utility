import 'dart:collection';

import 'package:flutter/foundation.dart';

enum AppDebugLogLevel { debug, info, warn, error }

@immutable
class AppDebugLogEntry {
  const AppDebugLogEntry({
    required this.timestamp,
    required this.level,
    required this.scope,
    required this.message,
  });

  final DateTime timestamp;
  final AppDebugLogLevel level;
  final String scope;
  final String message;
}

class AppDebugLogService extends ChangeNotifier {
  AppDebugLogService._();

  static final AppDebugLogService instance = AppDebugLogService._();

  static const int _maxEntries = 1000;
  static const int _maxEntriesRelease = 300;
  final List<AppDebugLogEntry> _entries = <AppDebugLogEntry>[];

  UnmodifiableListView<AppDebugLogEntry> get entries =>
      UnmodifiableListView<AppDebugLogEntry>(_entries);

  void debug(String scope, String message) {
    _add(AppDebugLogLevel.debug, scope, message);
  }

  void info(String scope, String message) {
    _add(AppDebugLogLevel.info, scope, message);
  }

  void warn(String scope, String message) {
    _add(AppDebugLogLevel.warn, scope, message);
  }

  void error(String scope, String message) {
    _add(AppDebugLogLevel.error, scope, message);
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  void _add(AppDebugLogLevel level, String scope, String message) {
    // In release builds, suppress verbose log traffic to reduce overhead.
    if (kReleaseMode &&
        (level == AppDebugLogLevel.debug || level == AppDebugLogLevel.info)) {
      return;
    }
    debugPrint('[${level.name}] [$scope] $message');
    _entries.add(
      AppDebugLogEntry(
        timestamp: DateTime.now(),
        level: level,
        scope: scope,
        message: message,
      ),
    );
    final maxEntries = kReleaseMode ? _maxEntriesRelease : _maxEntries;
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    notifyListeners();
  }
}
