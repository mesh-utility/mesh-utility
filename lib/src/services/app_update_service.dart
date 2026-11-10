import 'package:flutter/foundation.dart';
import 'package:mesh_utility/src/platform/local_contacts_supported.dart';
import 'package:mesh_utility/src/services/reax_database.dart';
import 'package:mesh_utility/src/services/update_check.dart';
import 'package:mesh_utility/src/services/update_installer.dart';

class AppUpdateService extends ChangeNotifier {
  static const _lastCheckKey = 'updates:lastCheckMs';
  static const _skippedKey = 'updates:skippedTag';
  static const checkInterval = Duration(hours: 12);

  AppReleaseInfo? available;
  String? statusMessage;
  bool checking = false;
  bool installing = false;

  /// Current app label, e.g. `Alpha-17` or `1.0.0-alpha.17+17`.
  String currentVersionLabel;

  AppUpdateService({required this.currentVersionLabel});

  Future<int?> _loadLastCheckMs() async {
    if (!localContactsSupported) return null;
    final raw = await (await ReaxDatabase.instance()).get(_lastCheckKey);
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return null;
  }

  Future<void> _saveLastCheckMs(int ms) async {
    if (!localContactsSupported) return;
    await (await ReaxDatabase.instance()).put(_lastCheckKey, ms);
  }

  Future<String?> _loadSkipped() async {
    if (!localContactsSupported) return null;
    final raw = await (await ReaxDatabase.instance()).get(_skippedKey);
    return raw?.toString();
  }

  Future<void> skipVersion(String tag) async {
    if (!localContactsSupported) return;
    await (await ReaxDatabase.instance()).put(_skippedKey, tag);
    if (available?.tagName == tag) {
      available = null;
      notifyListeners();
    }
  }

  Future<AppReleaseInfo?> check({bool force = false}) async {
    if (!localContactsSupported) return null;
    if (checking) return available;
    checking = true;
    statusMessage = null;
    notifyListeners();
    try {
      if (!force) {
        final last = await _loadLastCheckMs();
        if (last != null) {
          final elapsed = DateTime.now().millisecondsSinceEpoch - last;
          if (elapsed < checkInterval.inMilliseconds) {
            return available;
          }
        }
      }
      final latest = await fetchLatestRelease();
      await _saveLastCheckMs(DateTime.now().millisecondsSinceEpoch);
      if (latest == null) {
        statusMessage = force ? 'Could not reach GitHub releases.' : null;
        return null;
      }
      final skipped = await _loadSkipped();
      // Missing platform assets are not recorded as updates:skippedTag.
      final decision = decideUpdateAvailability(
        latest: latest,
        currentVersion: currentVersionLabel,
        skippedTag: skipped,
        force: force,
        platform: defaultTargetPlatform,
      );
      available = decision.release;
      statusMessage = decision.statusMessage;
      return decision.release;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<String?> installAvailable() async {
    final rel = available;
    if (rel == null) return 'No update available.';
    installing = true;
    notifyListeners();
    try {
      void status(String s) {
        statusMessage = s;
        notifyListeners();
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        return await installAndroidApk(release: rel, onStatus: status);
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        return await installLinuxArchive(release: rel, onStatus: status);
      }
      return 'Updates are not supported on this platform.';
    } finally {
      installing = false;
      notifyListeners();
    }
  }
}
