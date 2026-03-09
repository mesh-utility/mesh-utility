import 'package:mesh_utility/src/services/reax_database.dart';

class AppSettings {
  const AppSettings({
    required this.workerUrl,
    required this.historyDays,
    required this.deadzoneDays,
    required this.privacyAccepted,
    required this.scanIntervalSeconds,
    required this.discoverWaitSeconds,
    required this.autoCenter,
    required this.smartScanEnabled,
    required this.smartScanDays,
    required this.forceOffline,
    required this.updateRadioPosition,
    required this.tileCachingEnabled,
    required this.unitSystem,
    required this.language,
    required this.statsRadiusMiles,
    required this.uploadBatchIntervalMinutes,
    required this.bleAutoConnect,
    required this.knownBleDeviceIds,
  });

  final String workerUrl;
  final int historyDays;
  final int deadzoneDays;
  final bool privacyAccepted;
  final int scanIntervalSeconds;
  final int discoverWaitSeconds;
  final bool autoCenter;
  final bool smartScanEnabled;
  final int smartScanDays;
  final bool forceOffline;
  final bool updateRadioPosition;
  final bool tileCachingEnabled;
  final String unitSystem;
  final String language;
  final int statsRadiusMiles;
  final int uploadBatchIntervalMinutes;
  final bool bleAutoConnect;
  final List<String> knownBleDeviceIds;

  static const defaults = AppSettings(
    workerUrl: 'http://127.0.0.1:8787',
    historyDays: 7,
    deadzoneDays: 7,
    privacyAccepted: false,
    scanIntervalSeconds: 40,
    discoverWaitSeconds: 40,
    autoCenter: true,
    smartScanEnabled: true,
    smartScanDays: 5,
    forceOffline: false,
    updateRadioPosition: false,
    tileCachingEnabled: false,
    unitSystem: 'imperial',
    language: 'en',
    statsRadiusMiles: 0,
    uploadBatchIntervalMinutes: 15,
    bleAutoConnect: false,
    knownBleDeviceIds: <String>[],
  );

  AppSettings copyWith({
    String? workerUrl,
    int? historyDays,
    int? deadzoneDays,
    bool? privacyAccepted,
    int? scanIntervalSeconds,
    int? discoverWaitSeconds,
    bool? autoCenter,
    bool? smartScanEnabled,
    int? smartScanDays,
    bool? forceOffline,
    bool? updateRadioPosition,
    bool? tileCachingEnabled,
    String? unitSystem,
    String? language,
    int? statsRadiusMiles,
    int? uploadBatchIntervalMinutes,
    bool? bleAutoConnect,
    List<String>? knownBleDeviceIds,
  }) {
    return AppSettings(
      workerUrl: workerUrl ?? this.workerUrl,
      historyDays: historyDays ?? this.historyDays,
      deadzoneDays: deadzoneDays ?? this.deadzoneDays,
      privacyAccepted: privacyAccepted ?? this.privacyAccepted,
      scanIntervalSeconds: scanIntervalSeconds ?? this.scanIntervalSeconds,
      discoverWaitSeconds: discoverWaitSeconds ?? this.discoverWaitSeconds,
      autoCenter: autoCenter ?? this.autoCenter,
      smartScanEnabled: smartScanEnabled ?? this.smartScanEnabled,
      smartScanDays: smartScanDays ?? this.smartScanDays,
      forceOffline: forceOffline ?? this.forceOffline,
      updateRadioPosition: updateRadioPosition ?? this.updateRadioPosition,
      tileCachingEnabled: tileCachingEnabled ?? this.tileCachingEnabled,
      unitSystem: unitSystem ?? this.unitSystem,
      language: language ?? this.language,
      statsRadiusMiles: statsRadiusMiles ?? this.statsRadiusMiles,
      uploadBatchIntervalMinutes:
          uploadBatchIntervalMinutes ?? this.uploadBatchIntervalMinutes,
      bleAutoConnect: bleAutoConnect ?? this.bleAutoConnect,
      knownBleDeviceIds: knownBleDeviceIds ?? this.knownBleDeviceIds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'workerUrl': workerUrl,
      'historyDays': historyDays,
      'deadzoneDays': deadzoneDays,
      'privacyAccepted': privacyAccepted,
      'scanIntervalSeconds': scanIntervalSeconds,
      'discoverWaitSeconds': discoverWaitSeconds,
      'autoCenter': autoCenter,
      'smartScanEnabled': smartScanEnabled,
      'smartScanDays': smartScanDays,
      'forceOffline': forceOffline,
      'updateRadioPosition': updateRadioPosition,
      'tileCachingEnabled': tileCachingEnabled,
      'unitSystem': unitSystem,
      'language': language,
      'statsRadiusMiles': statsRadiusMiles,
      'uploadBatchIntervalMinutes': uploadBatchIntervalMinutes,
      'bleAutoConnect': bleAutoConnect,
      'knownBleDeviceIds': knownBleDeviceIds,
    };
  }

  static AppSettings fromJson(Map<String, dynamic> json) {
    return AppSettings(
      workerUrl: (json['workerUrl'] as String?) ?? defaults.workerUrl,
      historyDays:
          (json['historyDays'] as num?)?.toInt() ?? defaults.historyDays,
      deadzoneDays:
          (json['deadzoneDays'] as num?)?.toInt() ?? defaults.deadzoneDays,
      privacyAccepted:
          (json['privacyAccepted'] as bool?) ?? defaults.privacyAccepted,
      scanIntervalSeconds:
          (json['scanIntervalSeconds'] as num?)?.toInt() ??
          defaults.scanIntervalSeconds,
      discoverWaitSeconds: _clampDiscoverWaitSeconds(
        (json['discoverWaitSeconds'] as num?)?.toInt() ??
            defaults.discoverWaitSeconds,
      ),
      autoCenter: (json['autoCenter'] as bool?) ?? defaults.autoCenter,
      smartScanEnabled:
          (json['smartScanEnabled'] as bool?) ?? defaults.smartScanEnabled,
      smartScanDays:
          (json['smartScanDays'] as num?)?.toInt() ?? defaults.smartScanDays,
      forceOffline: (json['forceOffline'] as bool?) ?? defaults.forceOffline,
      updateRadioPosition:
          (json['updateRadioPosition'] as bool?) ??
          defaults.updateRadioPosition,
      tileCachingEnabled:
          (json['tileCachingEnabled'] as bool?) ?? defaults.tileCachingEnabled,
      unitSystem: (json['unitSystem'] as String?) ?? defaults.unitSystem,
      language: (json['language'] as String?) ?? defaults.language,
      statsRadiusMiles:
          (json['statsRadiusMiles'] as num?)?.toInt() ??
          defaults.statsRadiusMiles,
      uploadBatchIntervalMinutes:
          (json['uploadBatchIntervalMinutes'] as num?)?.toInt() ??
          defaults.uploadBatchIntervalMinutes,
      bleAutoConnect:
          (json['bleAutoConnect'] as bool?) ?? defaults.bleAutoConnect,
      knownBleDeviceIds: ((json['knownBleDeviceIds'] as List?) ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }

  static int _clampDiscoverWaitSeconds(int value) {
    if (value < 5) return 5;
    if (value > 120) return 120;
    return value;
  }
}

class SettingsStore {
  static const _settingsKey = 'settings:app';

  Future<AppSettings> load() async {
    final db = await ReaxDatabase.instance();
    final raw = await db.get(_settingsKey);
    if (raw is Map<String, dynamic>) {
      return AppSettings.fromJson(raw);
    }

    if (raw is Map) {
      return AppSettings.fromJson(raw.cast<String, dynamic>());
    }

    return AppSettings.defaults;
  }

  Future<void> save(AppSettings settings) async {
    final db = await ReaxDatabase.instance();
    await db.put(_settingsKey, settings.toJson());
  }
}
