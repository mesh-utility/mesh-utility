import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/config/app_config.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/app_i18n.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/scan_aggregator.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/src/services/tile_cache_service.dart';
import 'package:mesh_utility/src/services/worker_api.dart';
import 'package:mesh_utility/transport/ble_transport.dart';
import 'package:mesh_utility/transport/protocol.dart';
import 'package:mesh_utility/transport/transport.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:universal_ble/universal_ble.dart';

class AppState extends ChangeNotifier {
  static const int _otherParamsAllowTelemetryFlags = 0;
  static const int _otherParamsMultiAcks = 0;
  static const int _advertLocationPolicyDisabled = 0;
  static const int _advertLocationPolicyCompanion = 1;
  static const List<String> _offlineTileTemplates = [
    'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
  ];

  AppState({
    required SettingsStore settingsStore,
    required LocalStore localStore,
    required Transport transport,
    AppDebugLogService? debugLogService,
  }) : _settingsStore = settingsStore,
       _localStore = localStore,
       _transport = transport,
       _debugLog = debugLogService ?? AppDebugLogService.instance {
    if (_transport is BleTransport) {
      final ble = _transport;
      ble.onRequestPin = (deviceId) async {
        _debugLog.info('ble', 'PIN/passkey requested for $deviceId');
        if (onBlePinRequest == null) {
          _debugLog.warn('ble', 'No UI PIN handler registered for $deviceId');
          return null;
        }
        return onBlePinRequest!(deviceId);
      };
      ble.onScanResult = (deviceId, deviceName) {
        final name = deviceName.isEmpty ? '(Unnamed)' : deviceName;
        _bleDeviceNamesById[deviceId] = name;
        final label = '$name [$deviceId]';
        if (bleScanDevices.contains(label)) return;
        bleScanDevices = [...bleScanDevices, label];
        notifyListeners();
      };
      ble.onConnectionStateChanged =
          ({required bool connected, String? deviceId, String? reason}) {
            if (connected) {
              return;
            }
            final wasScanning = bleScanning;
            if (!bleConnected && !bleConnecting) {
              return;
            }
            bleConnected = false;
            bleConnecting = false;
            bleBusy = false;
            bleScanning = false;
            bleScanStatus = 'idle';
            _bleAutoScanTimer?.cancel();
            _bleCountdownTimer?.cancel();
            bleNextScanCountdown = null;
            _autoScanRemainingSeconds = 0;
            _smartScanPausedForRecentCoverage = false;
            _smartScanPausedZoneId = null;
            _connectedRadioMeshIdPrefix = null;
            _connectedRadioPublicKeyHex = null;
            _connectedRadioDisplayName = null;
            _lastSelfInfoHex = null;
            _lastSelfInfoText = null;
            bleStatus = 'BLE disconnected';
            _resumeAutoScanAfterReconnect = wasScanning;
            _debugLog.warn(
              'ble',
              'Connection lost device=${deviceId ?? 'unknown'} reason=${reason ?? 'unknown'}',
            );
            notifyListeners();
            if (!_manualBleDisconnectRequested) {
              unawaited(_attemptAutoReconnect(reason: reason));
            }
          };
    }
    if (kIsWeb) {
      bleStatus = 'BLE ready (web)';
    }
  }

  final SettingsStore _settingsStore;
  final LocalStore _localStore;
  final Transport _transport;
  final AppDebugLogService _debugLog;

  late final TransportProtocol _bleProtocol = TransportProtocol(_transport);
  final ProtocolCommandRegistry _protocol = const ProtocolCommandRegistry();

  AppSettings settings = AppSettings.defaults;
  bool loading = true;
  bool syncing = false;
  String? error;
  DateTime? lastSyncAt;
  int lastSyncScanCount = 0;

  bool bleConnecting = false;
  bool bleConnected = false;
  bool bleBusy = false;
  bool bleScanning = false;
  bool bleDeviceScanInProgress = false;
  String bleStatus = 'BLE disconnected';
  String bleScanStatus = 'idle';
  List<NodeDiscoverResponse> bleDiscoveries = const [];
  int? bleNextScanCountdown;
  DateTime? bleLastDiscoverAt;
  int bleLastDiscoverCount = 0;
  String? bleLastDiscoverError;
  List<String> bleScanDevices = const [];
  String? bleSelectedDeviceId;
  double? deviceLatitude;
  double? deviceLongitude;
  double? deviceAltitude;
  DateTime? deviceLocationAt;
  String deviceLocationStatus = 'Location unavailable';
  Timer? _bleCountdownTimer;
  Timer? _bleAutoScanTimer;
  Timer? _periodicSyncTimer;
  StreamSubscription<Position>? _locationSubscription;
  Timer? _locationPollTimer;
  DateTime? _lastIpFallbackAt;
  final Map<String, String> _radioContactsByPrefix = {};
  final Map<String, String> _bleDeviceNamesById = {};
  bool _manualBleDisconnectRequested = false;

  void _setBleUnavailableStatus({String context = 'ble'}) {
    bleConnected = false;
    bleConnecting = false;
    bleBusy = false;
    bleScanning = false;
    bleDeviceScanInProgress = false;
    bleScanStatus = 'idle';
    bleStatus = _bleUnavailableStatusMessage();
    _debugLog.info(context, bleStatus);
    notifyListeners();
  }

  String _bleUnavailableStatusMessage() {
    if (!kIsWeb) return 'BLE unavailable on this platform';
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'BLE unavailable in iOS Safari. Use Bluefy or the native app.';
    }
    final scheme = Uri.base.scheme.toLowerCase();
    final host = Uri.base.host.toLowerCase();
    final isLocalhost =
        host == 'localhost' || host == '127.0.0.1' || host == '::1';
    final isSecureContext = scheme == 'https' || isLocalhost;
    if (!isSecureContext) {
      return 'Web BLE requires HTTPS on Android Chrome (localhost allowed for dev).';
    }
    return 'BLE unavailable in this browser. Use Android Chrome/Edge with Web Bluetooth enabled.';
  }

  Future<bool> _ensureBleAvailable({String context = 'ble'}) async {
    if (_transport is! BleTransport) return false;
    try {
      final state = await _transport.getAvailabilityState();
      if (state == AvailabilityState.unsupported) {
        _setBleUnavailableStatus(context: context);
        return false;
      }
      return true;
    } catch (e) {
      bleStatus = 'BLE availability check failed: $e';
      _debugLog.warn(context, bleStatus);
      notifyListeners();
      return false;
    }
  }

  bool _autoReconnectInProgress = false;
  bool _resumeAutoScanAfterReconnect = false;
  bool _discoverLocationRefreshInFlight = false;
  DateTime? _lastDiscoverLocationRefreshAt;
  bool _smartScanReevaluatePending = false;
  bool _smartScanPausedForRecentCoverage = false;
  String? _smartScanPausedZoneId;
  int _autoScanRemainingSeconds = 0;
  String? _connectedRadioMeshIdPrefix;
  String? _connectedRadioPublicKeyHex;
  String? _connectedRadioDisplayName;
  String? _lastSelfInfoHex;
  String? _lastSelfInfoText;
  bool _deleteInProgress = false;
  final Stopwatch _monotonicClock = Stopwatch()..start();
  DateTime? _internetTimeAnchorUtc;
  Duration? _internetTimeAnchorElapsed;
  DateTime? _lastPeriodicSyncInternetUtc;
  bool _internetTimeRefreshInFlight = false;
  Future<String?> Function(String deviceId)? onBlePinRequest;

  List<RawScan> rawScans = const [];
  List<CoverageZone> coverageZones = const [];
  List<MeshNode> nodes = const [];
  List<ScanResult> scanResults = const [];
  List<AppDebugLogEntry> get debugLogs => _debugLog.entries;
  String? get connectedRadioName {
    if (!bleConnected) return null;
    final name =
        connectedRadioDisplayName ??
        _cleanRadioDisplayName(_selectedBleDeviceName());
    if (name.isEmpty) return null;
    return name;
  }

  String? get connectedRadioDisplayName => _connectedRadioDisplayName;
  String? get connectedRadioMeshId8 => _connectedRadioMeshId8();
  String? get connectedRadioPublicKeyHex => _connectedRadioPublicKeyHex;
  bool get deleteInProgress => _deleteInProgress;
  Map<String, String> get knownContactNames =>
      Map<String, String>.unmodifiable(_radioContactsByPrefix);
  int get localScanCount => rawScans.length;
  int get uploadQueueCount =>
      rawScans.where((scan) => scan.uploadEligible).length;
  List<RawScan> get uploadCandidates =>
      rawScans.where((scan) => scan.uploadEligible).toList(growable: false);
  (double, double)? get currentObserverPosition {
    if (deviceLatitude != null && deviceLongitude != null) {
      return (deviceLatitude!, deviceLongitude!);
    }
    if (scanResults.isEmpty) return null;
    final latest = scanResults.first;
    return (latest.latitude, latest.longitude);
  }

  Future<void> initialize() async {
    _debugLog.info('app_state', 'Initializing app state');
    loading = true;
    notifyListeners();

    settings = await _settingsStore.load();
    if (!settings.privacyAccepted && !settings.forceOffline) {
      settings = settings.copyWith(forceOffline: true);
      await _settingsStore.save(settings);
    }
    AppI18n.instance.setLanguage(settings.language);
    rawScans = _normalizeRawScans(await _localStore.loadRawScans());
    rawScans = _applyDeadzoneSuccessPrecedence(rawScans, source: 'local_cache');
    await _localStore.saveRawScans(rawScans);
    _rebuildDerivedData();

    loading = false;
    notifyListeners();

    if (settings.bleAutoConnect && settings.knownBleDeviceIds.isNotEmpty) {
      bleSelectedDeviceId = settings.knownBleDeviceIds.first;
      if (_transport is BleTransport) {
        (_transport).preferredDeviceId = bleSelectedDeviceId;
      }
      unawaited(connectBle());
    }

    unawaited(_startDeviceLocationTracking());
    await syncFromWorker();
    _configurePeriodicSyncTimer();
  }

  Future<void> updateSettings(AppSettings next) async {
    final previous = settings;
    settings = !next.privacyAccepted && !next.forceOffline
        ? next.copyWith(forceOffline: true)
        : next;
    AppI18n.instance.setLanguage(settings.language);
    await _settingsStore.save(settings);
    notifyListeners();

    final smartChanged =
        previous.smartScanEnabled != settings.smartScanEnabled ||
        previous.smartScanDays != settings.smartScanDays;
    if (smartChanged && bleScanning && bleConnected) {
      if (bleBusy) {
        _smartScanReevaluatePending = true;
        _debugLog.info(
          'smart_scan',
          'Settings changed during active scan; queued smart-scan re-evaluation',
        );
      } else {
        _debugLog.info(
          'smart_scan',
          'Settings changed; re-evaluating smart scan immediately',
        );
        unawaited(_runAutoScanCycle());
      }
    }
    if (previous.uploadBatchIntervalMinutes !=
            settings.uploadBatchIntervalMinutes ||
        previous.forceOffline != settings.forceOffline) {
      _configurePeriodicSyncTimer();
    }
    if (previous.updateRadioPosition != settings.updateRadioPosition &&
        bleConnected) {
      unawaited(_applyCompanionLocationPolicyFromSettings());
    }
  }

  Future<void> setAutoCenter(bool value) async {
    await updateSettings(settings.copyWith(autoCenter: value));
  }

  Future<void> syncFromWorker() async {
    if (syncing) return;
    _debugLog.info('sync', 'Starting worker sync');
    syncing = true;
    error = null;
    notifyListeners();

    try {
      if (settings.forceOffline) {
        _debugLog.warn(
          'sync',
          'Skipped worker sync because offline mode is enabled',
        );
        syncing = false;
        notifyListeners();
        return;
      }

      final api = WorkerApi(
        AppConfig.deployedWorkerUrl,
        fallbackBaseUrl: AppConfig.fallbackWorkerUrl,
      );
      final connectedRadioId = _connectedRadioMeshId8();
      final localOnlyBeforeSync = rawScans
          .where((scan) => !scan.downloadedFromWorker)
          .toList(growable: false);
      if (localOnlyBeforeSync.isNotEmpty) {
        await _uploadPendingScans(api, localOnlyBeforeSync);
      }
      final workerScans = await api
          .fetchRawScans(
            historyDays: settings.historyDays,
            deadzoneDays: settings.deadzoneDays,
            connectedRadioId: connectedRadioId,
          )
          .then(
            (value) => value
                .map((scan) => scan.copyWith(downloadedFromWorker: true))
                .toList(growable: false),
          );
      final normalizedWorkerScans = _normalizeRawScans(
        _sanitizeDeadzoneRadioIds(workerScans, connectedRadioId),
      );
      final workerScansWithPrecedence = _applyDeadzoneSuccessPrecedence(
        normalizedWorkerScans,
        source: 'worker',
      );
      lastSyncScanCount = workerScans.length;
      lastSyncAt = DateTime.now();

      if (workerScansWithPrecedence.isNotEmpty) {
        _debugLog.info(
          'sync',
          'Fetched ${workerScansWithPrecedence.length} raw scans from worker',
        );
        final merged = <RawScan>[...workerScansWithPrecedence];
        final seen = <String>{};
        for (final scan in merged) {
          seen.add(_scanIdentity(scan));
        }
        var preservedLocal = 0;
        for (final local in localOnlyBeforeSync) {
          final key = _scanIdentity(local);
          if (seen.add(key)) {
            merged.add(local);
            preservedLocal += 1;
          }
        }
        rawScans = _applyDeadzoneSuccessPrecedence(
          _normalizeRawScans(merged),
          source: 'merged',
        );
        _debugLog.info(
          'sync',
          'Merged ${workerScansWithPrecedence.length} worker scans with '
              '$preservedLocal preserved local scan(s) => ${rawScans.length} total',
        );
        _applyKnownContactsBackfill();
        await _localStore.saveRawScans(rawScans);
      }

      try {
        final workerZones = await api.fetchCoverageZones(
          historyDays: settings.historyDays,
          deadzoneDays: settings.deadzoneDays,
          connectedRadioId: connectedRadioId,
        );
        _debugLog.info(
          'sync',
          'Fetched ${workerZones.length} coverage zones from worker',
        );
        coverageZones = _applyZoneDeadzonePrecedence(
          _sanitizeDeadzoneZoneRadioIds(workerZones, connectedRadioId),
          source: 'worker',
        );
      } catch (_) {
        _debugLog.warn(
          'sync',
          'Coverage zones endpoint failed, falling back to local aggregation',
        );
        coverageZones = aggregateScansToZones(rawScans);
      }

      _rebuildDerivedData(skipZones: true);
      _captureInternetTimeAnchor(api.lastServerDateUtc);
      final internetNow = _estimatedInternetNowUtc();
      if (internetNow != null) {
        _lastPeriodicSyncInternetUtc = internetNow;
      }
    } catch (e) {
      error = e.toString();
      _debugLog.error('sync', 'Worker sync failed: $e');
      _rebuildDerivedData();
    } finally {
      _debugLog.info('sync', 'Worker sync finished');
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> connectBle() async {
    if (!await _ensureBleAvailable(context: 'ble')) {
      return;
    }
    if (!await _ensureAndroidLocationReadyForBle()) {
      return;
    }
    if (bleConnecting || bleConnected) return;
    if (bleSelectedDeviceId == null || bleSelectedDeviceId!.isEmpty) {
      bleStatus = 'Select a BLE device first';
      notifyListeners();
      return;
    }
    _manualBleDisconnectRequested = false;
    if (_transport is BleTransport) {
      (_transport).preferredDeviceId = bleSelectedDeviceId;
    }
    _debugLog.info('ble', 'Connect requested');
    bleConnecting = true;
    if (_transport is BleTransport) {
      await _transport.stopDeviceScan();
      bleDeviceScanInProgress = false;
    }
    bleStatus = 'BLE connecting...';
    notifyListeners();

    try {
      await _bleProtocol.run(_protocol.connect());
      bleConnected = _transport.isConnected;
      final selectedName = _cleanRadioDisplayName(_selectedBleDeviceName());
      if (selectedName.isNotEmpty) {
        _connectedRadioDisplayName = selectedName;
      }
      _debugLog.info(
        'ble',
        'Connected via ${selectedName.isNotEmpty ? selectedName : _transport.name}',
      );
      bleStatus = selectedName.isNotEmpty
          ? 'Connected ($selectedName)'
          : 'Connected';
      if (bleSelectedDeviceId != null &&
          bleSelectedDeviceId!.isNotEmpty &&
          !settings.knownBleDeviceIds.contains(bleSelectedDeviceId)) {
        final updatedKnown = [
          ...settings.knownBleDeviceIds,
          bleSelectedDeviceId!,
        ];
        await updateSettings(
          settings.copyWith(knownBleDeviceIds: updatedKnown),
        );
      }
      await _requestSelfInfo();
      await _syncContactsAndBackfillNames();
      await _applyCompanionLocationPolicyFromSettings();
    } catch (e) {
      bleConnected = false;
      _debugLog.error('ble', 'Connect failed: $e');
      bleStatus = 'BLE connect failed: $e';
    } finally {
      bleConnecting = false;
      notifyListeners();
    }
  }

  Future<bool> _ensureAndroidLocationReadyForBle() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        deviceLocationStatus = 'Location services disabled';
        _debugLog.warn('location', '$deviceLocationStatus (BLE precheck)');
        notifyListeners();
        await Geolocator.openLocationSettings();
        return false;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        deviceLocationStatus = 'Location permission denied';
        _debugLog.warn('location', '$deviceLocationStatus (BLE precheck)');
        notifyListeners();
        return false;
      }
      if (permission == LocationPermission.deniedForever) {
        deviceLocationStatus = 'Location permission denied forever';
        _debugLog.warn('location', '$deviceLocationStatus (BLE precheck)');
        notifyListeners();
        await Geolocator.openAppSettings();
        return false;
      }

      // Android background permission requires a separate permission flow.
      final alwaysStatus = await ph.Permission.locationAlways.status;
      if (!alwaysStatus.isGranted) {
        final requestStatus = await ph.Permission.locationAlways.request();
        if (!requestStatus.isGranted) {
          deviceLocationStatus = 'Background location not granted';
          _debugLog.warn(
            'location',
            '$deviceLocationStatus (BLE precheck)',
          );
          notifyListeners();
          if (requestStatus.isPermanentlyDenied) {
            await Geolocator.openAppSettings();
          }
          return false;
        }
      }
      return true;
    } catch (e) {
      _debugLog.warn('location', 'BLE location precheck failed: $e');
      return true;
    }
  }

  Future<void> disconnectBle() async {
    _debugLog.info('ble', 'Disconnect requested');
    _manualBleDisconnectRequested = true;
    _resumeAutoScanAfterReconnect = false;
    bleBusy = false;
    bleConnecting = false;
    bleScanning = false;
    bleScanStatus = 'idle';
    _bleAutoScanTimer?.cancel();
    _bleCountdownTimer?.cancel();
    bleNextScanCountdown = null;
    _autoScanRemainingSeconds = 0;
    _smartScanPausedForRecentCoverage = false;
    _smartScanPausedZoneId = null;
    try {
      await _transport.disconnect();
    } catch (_) {}
    _debugLog.info('ble', 'Disconnected');
    bleConnected = false;
    bleStatus = 'BLE disconnected';
    _connectedRadioMeshIdPrefix = null;
    _connectedRadioPublicKeyHex = null;
    _connectedRadioDisplayName = null;
    _lastSelfInfoHex = null;
    _lastSelfInfoText = null;
    notifyListeners();
  }

  void selectBleDevice(String deviceId) {
    bleSelectedDeviceId = deviceId;
    if (_transport is BleTransport) {
      (_transport).preferredDeviceId = deviceId;
    }
    _debugLog.info('ble', 'Selected BLE device: $deviceId');
    bleStatus = 'Selected device: $deviceId';
    notifyListeners();
  }

  Future<void> scanBleDevices() async {
    if (!await _ensureBleAvailable(context: 'ble_scan')) {
      return;
    }
    if (_transport is! BleTransport ||
        bleBusy ||
        bleConnecting ||
        bleConnected ||
        bleDeviceScanInProgress) {
      return;
    }
    final ble = _transport;
    bleDeviceScanInProgress = true;
    bleStatus = 'Scanning BLE devices...';
    bleScanDevices = const [];
    notifyListeners();
    try {
      await ble.scanDevices();
      bleStatus = bleScanDevices.isEmpty
          ? 'No BLE devices found'
          : 'Select a BLE device from results, then Connect';
    } catch (e) {
      final message = e.toString();
      if (message.contains('bluetoothNotEnabled') ||
          message.contains('BLUETOOTH_NOT_ENABLED')) {
        bleStatus = 'Bluetooth is off. Turn Bluetooth on, then scan again.';
      } else {
        bleStatus = 'BLE scan failed: $e';
      }
      _debugLog.warn('ble_scan', bleStatus);
    } finally {
      bleDeviceScanInProgress = false;
    }
    notifyListeners();
  }

  Future<void> runNodeDiscover({
    Duration? waitForResponses,
    bool retryOnDisconnect = true,
  }) async {
    if (!await _ensureBleAvailable(context: 'ble_discover')) {
      return;
    }
    final discoverWait =
        waitForResponses ?? Duration(seconds: settings.discoverWaitSeconds);
    _debugLog.info('ble_discover', 'node_discover requested');
    if (!bleConnected) {
      await connectBle();
      if (!bleConnected) return;
    }

    if (bleBusy) return;
    bleBusy = true;
    bleScanStatus = 'advertising';
    bleStatus = 'Discovering...';
    bleDiscoveries = const [];
    bleLastDiscoverError = null;
    bleNextScanCountdown = discoverWait.inSeconds;
    notifyListeners();

    final byPrefix = <String, NodeDiscoverResponse>{};
    late final StreamSubscription<NodeDiscoverResponse> discoverSub;
    late final StreamSubscription<NodeDiscoverAdvertResponse> advertSub;
    late final StreamSubscription<Uint8List> rawSub;
    var unknownFrameLogs = 0;

    discoverSub = _bleProtocol.nodeDiscoverResponses().listen((response) {
      byPrefix[response.publicKeyPrefix] = response;
      unawaited(_refreshLocationForDiscoverResponse());
      bleDiscoveries = byPrefix.values.toList();
      _debugLog.debug(
        'ble_discover',
        'Response ${response.publicKeyPrefix} RSSI=${response.rssi} SNR=${response.snr}',
      );
      bleStatus = 'node_discover: ${bleDiscoveries.length} response(s)';
      notifyListeners();
    });
    advertSub = _bleProtocol.nodeDiscoverAdvertResponses().listen((advert) {
      final existing = byPrefix[advert.publicKeyPrefix];
      if (existing == null) {
        byPrefix[advert.publicKeyPrefix] = NodeDiscoverResponse(
          snr: 0,
          rssi: 0,
          snrIn: 0,
          nodeType: advert.nodeType,
          tagHex: '',
          publicKeyPrefix: advert.publicKeyPrefix,
          name: advert.name,
        );
      } else if (existing.name.trim().isEmpty &&
          advert.name.trim().isNotEmpty) {
        byPrefix[advert.publicKeyPrefix] = NodeDiscoverResponse(
          snr: existing.snr,
          rssi: existing.rssi,
          snrIn: existing.snrIn,
          nodeType: existing.nodeType,
          tagHex: existing.tagHex,
          publicKeyPrefix: existing.publicKeyPrefix,
          name: advert.name,
        );
      }
      unawaited(_refreshLocationForDiscoverResponse());
      bleDiscoveries = byPrefix.values.toList();
      bleStatus = 'node_discover: ${bleDiscoveries.length} response(s)';
      _debugLog.debug(
        'ble_discover',
        'Advert ${advert.publicKeyPrefix} name=${advert.name}',
      );
      notifyListeners();
    });
    rawSub = _transport.inbound.listen((frame) {
      final parsedControl = parseNodeDiscoverResponse(frame);
      final parsedAdvert = parseNodeDiscoverAdvertResponse(frame);
      if (parsedControl != null || parsedAdvert != null) {
        return;
      }
      if (unknownFrameLogs >= 20) return;
      unknownFrameLogs += 1;
      final code = frame.isNotEmpty ? frame.first : -1;
      final headBytes = frame.length > 12 ? frame.sublist(0, 12) : frame;
      final headHex = headBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      _debugLog.debug(
        'ble_discover_diag',
        'non-discover frame code=0x${code.toRadixString(16)} len=${frame.length} head=$headHex',
      );
    });

    var retryDiscoverAfterReconnect = false;
    try {
      await _bleProtocol.run(_protocol.nodeDiscover());
      bleScanStatus = 'waiting';
      _bleCountdownTimer?.cancel();
      _bleCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        final current = bleNextScanCountdown ?? 0;
        if (current <= 1) {
          bleNextScanCountdown = 0;
          timer.cancel();
        } else {
          bleNextScanCountdown = current - 1;
        }
        notifyListeners();
      });
      final start = DateTime.now();
      final deadline = start.add(discoverWait);
      var resentDiscover = false;
      while (DateTime.now().isBefore(deadline)) {
        if (!bleConnected || !_transport.isConnected) {
          throw StateError('BLE disconnected during node_discover');
        }
        if (!resentDiscover &&
            byPrefix.isEmpty &&
            DateTime.now().difference(start).inMilliseconds >=
                discoverWait.inMilliseconds ~/ 2) {
          resentDiscover = true;
          _debugLog.info(
            'ble_discover',
            'No responses yet; resending node_discover once',
          );
          await _bleProtocol.run(_protocol.nodeDiscover());
        }
        final remainingMs = deadline.difference(DateTime.now()).inMilliseconds;
        final sliceMs = remainingMs > 250 ? 250 : remainingMs;
        if (sliceMs <= 0) break;
        await Future<void>.delayed(Duration(milliseconds: sliceMs));
      }
      _bleCountdownTimer?.cancel();
      final appended = _appendDiscoverScansWithOsLocation(byPrefix.values);
      if (appended > 0) {
        await _localStore.saveRawScans(rawScans);
        _rebuildDerivedData();
        _debugLog.info(
          'ble_discover',
          'Stored $appended local scan(s) with OS location',
        );
      }
      bleScanStatus = 'done';
      bleStatus =
          'node_discover completed (${bleDiscoveries.length} response(s))';
      _debugLog.info(
        'ble_discover',
        'Completed with ${bleDiscoveries.length} response(s)',
      );
      bleLastDiscoverCount = bleDiscoveries.length;
      bleLastDiscoverAt = DateTime.now();
      bleNextScanCountdown = null;
    } catch (e) {
      bleScanStatus = 'error';
      bleStatus = 'node_discover failed: $e';
      _debugLog.error('ble_discover', 'Failed: $e');
      bleLastDiscoverError = e.toString();
      bleNextScanCountdown = null;
      if (!_transport.isConnected) {
        bleConnected = false;
        if (retryOnDisconnect &&
            !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.android) {
          retryDiscoverAfterReconnect = true;
          _debugLog.warn(
            'ble_discover',
            'Discover failed due to disconnect; scheduling one reconnect+retry',
          );
        }
      }
    } finally {
      await discoverSub.cancel();
      await advertSub.cancel();
      await rawSub.cancel();
      bleBusy = false;
      if (_smartScanReevaluatePending && bleScanning && bleConnected) {
        _smartScanReevaluatePending = false;
        _debugLog.info(
          'smart_scan',
          'Running queued smart-scan re-evaluation after active scan',
        );
        unawaited(_runAutoScanCycle());
      }
      notifyListeners();
    }

    if (retryDiscoverAfterReconnect) {
      await connectBle();
      if (!bleConnected || !_transport.isConnected) {
        _debugLog.warn(
          'ble_discover',
          'Reconnect failed; discover retry skipped',
        );
        return;
      }
      _debugLog.info('ble_discover', 'Retrying node_discover after reconnect');
      await runNodeDiscover(
        waitForResponses: discoverWait,
        retryOnDisconnect: false,
      );
    }
  }

  int _appendDiscoverScansWithOsLocation(
    Iterable<NodeDiscoverResponse> responses,
  ) {
    final lat = deviceLatitude;
    final lng = deviceLongitude;
    if (lat == null || lng == null) {
      _debugLog.warn(
        'ble_discover',
        'No OS location fix available; skipping local scan append',
      );
      return 0;
    }
    final now = DateTime.now();
    final connectedMeshId8 = _connectedRadioMeshId8();
    if (connectedMeshId8 == null || connectedMeshId8.isEmpty) {
      _debugLog.warn(
        'scan_store',
        'Connected mesh radio ID unavailable; refusing to store scans with BLE MAC fallback',
      );
      return 0;
    }
    final appended = <RawScan>[];
    for (final response in responses) {
      final nodeId8 = _safePublicRadioId(response.publicKeyPrefix);
      if (nodeId8 == null || nodeId8.isEmpty) {
        _debugLog.warn(
          'scan_store',
          'Skipping discover response with unsafe node id: ${response.publicKeyPrefix}',
        );
        continue;
      }
      final scan = RawScan(
        observerId: connectedMeshId8,
        nodeId: nodeId8,
        latitude: lat,
        longitude: lng,
        rssi: response.rssi.toDouble(),
        snr: response.snr,
        snrIn: response.snrIn,
        altitude: deviceAltitude,
        timestamp: now,
        receivedAt: now,
        senderName: response.name.trim().isEmpty ? nodeId8 : response.name,
        receiverName: (_connectedRadioDisplayName ?? '').trim().isEmpty
            ? connectedMeshId8
            : _connectedRadioDisplayName!.trim(),
        radioId: connectedMeshId8,
        downloadedFromWorker: false,
      );
      appended.add(_normalizeRawScanIds(scan));
      _debugLog.info(
        'scan_store',
        'radio=${scan.radioId ?? 'unknown'} node=${scan.nodeId} '
            'lat=${lat.toStringAsFixed(6)} '
            'lng=${lng.toStringAsFixed(6)} rssi=${scan.rssi?.toStringAsFixed(1)}',
      );
    }
    if (appended.isNotEmpty) {
      rawScans = [...appended, ...rawScans];
    }
    return appended.length;
  }

  Future<void> _syncContactsAndBackfillNames() async {
    if (!bleConnected) return;
    _debugLog.info('contacts', 'Requesting contacts from radio');

    final contacts = <String, String>{};
    final done = Completer<void>();
    late final StreamSubscription<RadioContact> contactSub;
    late final StreamSubscription<void> endSub;

    contactSub = _bleProtocol.contactResponses().listen((contact) {
      final prefix = contact.publicKeyPrefix.trim().toUpperCase();
      final name = contact.name.trim();
      if (prefix.isEmpty || name.isEmpty) return;
      contacts[prefix] = name;
      _debugLog.debug('contacts', 'contact $prefix => $name');
    });
    endSub = _bleProtocol.endOfContactsResponses().listen((_) {
      if (!done.isCompleted) done.complete();
    });

    try {
      await _bleProtocol.run(_protocol.getContacts());
      await Future.any([
        done.future,
        Future<void>.delayed(const Duration(seconds: 12)),
      ]);
    } finally {
      await contactSub.cancel();
      await endSub.cancel();
    }

    if (contacts.isEmpty) {
      _debugLog.info('contacts', 'No contacts returned from radio');
      return;
    }

    _radioContactsByPrefix
      ..clear()
      ..addAll(contacts);
    _updateConnectedRadioMeshIdFromContacts(contacts);
    _pruneSelfContact(_radioContactsByPrefix);

    final updated = _backfillScanNamesFromContacts(_radioContactsByPrefix);
    if (updated > 0) {
      await _localStore.saveRawScans(rawScans);
      _rebuildDerivedData();
      notifyListeners();
    }
    _debugLog.info(
      'contacts',
      'Loaded ${contacts.length} contact(s), updated $updated scan name field(s)',
    );
  }

  Future<void> _requestSelfInfo() async {
    if (!bleConnected) return;
    _debugLog.info('self_info', 'Requesting self info from radio');

    try {
      final frameFuture = _transport.inbound
          .firstWhere(
            (frame) => frame.isNotEmpty && frame[0] == respCodeSelfInfo,
          )
          .timeout(const Duration(seconds: 3));
      await _bleProtocol.run(_protocol.appStart());
      final frame = await frameFuture;
      final code = frame[0];
      // Self-info layout (meshcore): [code][type][tx][maxTx][pubKey:32]...
      // Use public key prefix, not bytes 1..8, to identify connected radio.
      final publicKeyHex = frame.length >= 36
          ? frame
                .sublist(4, 36)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
                .toUpperCase()
          : '';
      final prefix = frame.length >= 36
          ? frame
                .sublist(4, 12)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
                .toUpperCase()
          : (frame.length > 8
                ? frame
                      .sublist(1, 9)
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join()
                      .toUpperCase()
                : '');
      _lastSelfInfoHex = frame
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
      _lastSelfInfoText = _extractPrintableAscii(frame);
      if (prefix.isNotEmpty) {
        _connectedRadioMeshIdPrefix = prefix;
      }
      if (publicKeyHex.length == 64) {
        _connectedRadioPublicKeyHex = publicKeyHex;
      }
      final selfInfoName = _extractSelfInfoDisplayName(_lastSelfInfoText ?? '');
      if (selfInfoName != null && selfInfoName.isNotEmpty) {
        _connectedRadioDisplayName = selfInfoName;
      }
      _debugLog.info(
        'self_info',
        'Received self info response code=$code len=${frame.length} '
            '${prefix.isEmpty ? '' : 'prefix=$prefix'} '
            '${_lastSelfInfoText == null || _lastSelfInfoText!.isEmpty ? '' : 'text=${_lastSelfInfoText!}'}',
      );
    } catch (e) {
      _debugLog.warn(
        'self_info',
        'Self info request failed/timeout: $e. '
            'Falling back to device_info diagnostics only.',
      );
      try {
        final diagFrameFuture = _transport.inbound
            .firstWhere(
              (frame) => frame.isNotEmpty && frame[0] == respCodeDeviceInfo,
            )
            .timeout(const Duration(seconds: 2));
        await _bleProtocol.run(_protocol.deviceQuery());
        final frame = await diagFrameFuture;
        final text = _extractPrintableAscii(frame);
        _lastSelfInfoHex = frame
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase();
        _lastSelfInfoText = text;
        _debugLog.info(
          'self_info',
          'Received device_info len=${frame.length} '
              '${text.isEmpty ? '' : 'text=$text'}',
        );
      } catch (diagErr) {
        _debugLog.warn('self_info', 'Device info diagnostics failed: $diagErr');
      }
    }
  }

  int _backfillScanNamesFromContacts(Map<String, String> contacts) {
    var updates = 0;
    final next = <RawScan>[];
    final scanIdSample = <String>[];
    final contactPrefixSample = contacts.keys
        .map(_normalizeHexId)
        .where((v) => v.isNotEmpty)
        .take(12)
        .toList(growable: false);
    final connectedMesh = _normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
    var candidateScans = 0;
    var localCandidateScans = 0;
    var workerCandidateScans = 0;
    var globalNodeContactMatches = 0;
    var globalSenderBackfillable = 0;
    var globalReceiverBackfillable = 0;
    final globalBackfillExamples = <String>[];
    final contactIdCache = contacts.keys
        .map(_normalizeHexId)
        .where((v) => v.isNotEmpty)
        .toList(growable: false);
    for (final scan in rawScans) {
      final senderId = (scan.nodeId ?? '').trim().toUpperCase();
      final observerId = (scan.observerId ?? '').trim().toUpperCase();
      final senderCurrent = (scan.senderName ?? '').trim();
      final receiverCurrent = (scan.receiverName ?? '').trim();
      final senderMatchGlobal = _bestContactNameForId(contacts, senderId);
      final observerMatchGlobal = _bestContactNameForId(contacts, observerId);
      final senderNeedsBackfill =
          senderMatchGlobal != null && senderCurrent != senderMatchGlobal;
      final receiverNeedsBackfill =
          observerMatchGlobal != null && receiverCurrent != observerMatchGlobal;
      if (senderNeedsBackfill) {
        globalSenderBackfillable += 1;
      }
      if (receiverNeedsBackfill) {
        globalReceiverBackfillable += 1;
      }
      if (globalBackfillExamples.length < 8 && senderNeedsBackfill) {
        globalBackfillExamples.add(
          '${_normalizeHexId(senderId)}=>$senderMatchGlobal',
        );
      }
      final nodeNorm = _normalizeHexId(scan.nodeId ?? '');
      if (nodeNorm.isNotEmpty) {
        for (final contactId in contactIdCache) {
          if (_idsLikelySameDevice(nodeNorm, contactId)) {
            globalNodeContactMatches += 1;
            break;
          }
        }
      }
      candidateScans += 1;
      if (scan.downloadedFromWorker) {
        workerCandidateScans += 1;
      } else {
        localCandidateScans += 1;
      }
      if (scanIdSample.length < 24) {
        final s = _normalizeHexId(senderId);
        if (s.isNotEmpty) scanIdSample.add(s);
      }
      if (scanIdSample.length < 24) {
        final o = _normalizeHexId(observerId);
        if (o.isNotEmpty) scanIdSample.add(o);
      }
      final senderMatch = _bestContactNameForId(contacts, senderId);
      final observerMatch = _bestContactNameForId(contacts, observerId);

      final newSenderName = senderMatch ?? scan.senderName;
      final newReceiverName = observerMatch ?? scan.receiverName;
      final senderChanged = senderMatch != null && senderCurrent != senderMatch;
      final receiverChanged =
          observerMatch != null && receiverCurrent != observerMatch;
      if (!senderChanged && !receiverChanged) {
        next.add(scan);
        continue;
      }

      updates += (senderChanged ? 1 : 0) + (receiverChanged ? 1 : 0);
      next.add(
        _normalizeRawScanIds(
          RawScan(
            observerId: scan.observerId,
            nodeId: scan.nodeId,
            latitude: scan.latitude,
            longitude: scan.longitude,
            rssi: scan.rssi,
            snr: scan.snr,
            snrIn: scan.snrIn,
            altitude: scan.altitude,
            timestamp: scan.timestamp,
            receivedAt: scan.receivedAt,
            senderName: newSenderName,
            receiverName: newReceiverName,
            radioId: scan.radioId,
            downloadedFromWorker: scan.downloadedFromWorker,
          ),
        ),
      );
    }
    if (updates > 0) {
      rawScans = next;
    } else {
      _debugLog.debug(
        'contacts',
        'No ID matches for connected radio mesh=$connectedMesh. '
            'candidates=$candidateScans '
            'localCandidates=$localCandidateScans '
            'workerCandidates=$workerCandidateScans '
            'globalNodeContactMatches=$globalNodeContactMatches '
            'globalSenderBackfillable=$globalSenderBackfillable '
            'globalReceiverBackfillable=$globalReceiverBackfillable '
            'globalExamples=${globalBackfillExamples.join(";")} '
            'scanIds(sample)=${scanIdSample.toSet().take(12).join(",")} '
            'contactPrefixes(sample)=${contactPrefixSample.join(",")}',
      );
    }
    _debugLog.debug(
      'contacts',
      'Connected-radio backfill scope: mesh=$connectedMesh '
          'candidates=$candidateScans totalScans=${rawScans.length} '
          'globalSenderBackfillable=$globalSenderBackfillable '
          'globalReceiverBackfillable=$globalReceiverBackfillable',
    );
    return updates;
  }

  void _updateConnectedRadioMeshIdFromContacts(Map<String, String> contacts) {
    final frameHex = _lastSelfInfoHex ?? '';
    if (contacts.isEmpty) return;

    final existingMesh = _normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
    if (existingMesh.isNotEmpty) {
      final existingName = _bestContactNameForId(
        contacts,
        existingMesh,
      )?.trim();
      if (existingName != null && existingName.isNotEmpty) {
        _connectedRadioDisplayName = existingName;
        _debugLog.info(
          'self_info',
          'Connected radio mesh confirmed from self-info: $existingMesh name=$existingName',
        );
      } else {
        _debugLog.debug(
          'self_info',
          'Keeping self-info mesh id without contact-name override: $existingMesh',
        );
      }
      return;
    }

    final selectedName = _selectedBleDeviceName().toLowerCase();
    final selectedTokens = _nameTokens(selectedName);

    String? inferred;
    var bestScore = -1;
    for (final entry in contacts.entries) {
      final key = _normalizeHexId(entry.key);
      final name = entry.value.trim();
      if (key.isEmpty || name.isEmpty) continue;
      final lowerName = name.toLowerCase();
      var score = 0;
      if (frameHex.isNotEmpty && frameHex.contains(key)) {
        score += 100;
      }
      if (selectedTokens.isNotEmpty) {
        for (final token in selectedTokens) {
          if (token.length >= 4 && lowerName.contains(token)) {
            score += 18;
          }
        }
      }
      if (score > bestScore) {
        bestScore = score;
        inferred = key;
      }
    }
    final hasReliableSource = frameHex.isNotEmpty || selectedTokens.isNotEmpty;
    if (inferred == null || bestScore <= 0 || !hasReliableSource) {
      _debugLog.debug(
        'self_info',
        'No reliable connected-radio inference source '
            '(frameHex=${frameHex.isNotEmpty}, selectedTokens=${selectedTokens.length})',
      );
      return;
    }

    _connectedRadioMeshIdPrefix = inferred;
    _connectedRadioDisplayName = contacts[inferred]?.trim();
    _debugLog.info(
      'self_info',
      'Inferred connected radio mesh id from contacts: $inferred '
          '(score=$bestScore)'
          '${_connectedRadioDisplayName == null || _connectedRadioDisplayName!.isEmpty ? '' : ' name=${_connectedRadioDisplayName!}'}',
    );
  }

  String? _bestContactNameForId(Map<String, String> contacts, String id) {
    if (id.isEmpty) return null;
    final upper = _normalizeHexId(id);
    if (upper.isEmpty) return null;
    if (contacts.containsKey(upper)) return contacts[upper];

    // Stored scan IDs are often short prefixes; normalize matching on a shared
    // prefix window so 8-char IDs can match longer contact prefixes.
    final shortWindow = upper.length >= 8 ? upper.substring(0, 8) : upper;
    for (final entry in contacts.entries) {
      final prefix = _normalizeHexId(entry.key);
      if (prefix.isEmpty) continue;
      if (upper.startsWith(prefix) || prefix.startsWith(upper)) {
        return entry.value;
      }
      final prefixWindow = prefix.length >= 8 ? prefix.substring(0, 8) : prefix;
      if (shortWindow == prefixWindow) {
        return entry.value;
      }
    }
    return null;
  }

  String _normalizeHexId(String value) {
    final cleaned = value.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    return cleaned;
  }

  String _scanIdentity(RawScan scan) {
    final sender = _normalizeHexId(scan.nodeId ?? '');
    final observer = _normalizeHexId(scan.observerId ?? '');
    final ts = scan.effectiveTimestamp.toUtc().millisecondsSinceEpoch;
    return '$sender|$observer|'
        '${scan.latitude.toStringAsFixed(6)}|${scan.longitude.toStringAsFixed(6)}|'
        '${scan.rssi?.toStringAsFixed(1) ?? 'na'}|$ts';
  }

  bool _isDeadLikeScan(RawScan scan) {
    final nodeId = (scan.nodeId ?? '').trim();
    return nodeId.isEmpty || scan.rssi == null;
  }

  bool _isSuccessfulScan(RawScan scan) => !_isDeadLikeScan(scan);

  List<RawScan> _applyDeadzoneSuccessPrecedence(
    List<RawScan> scans, {
    required String source,
  }) {
    if (scans.isEmpty) return scans;
    final hexesWithSuccess = <String>{};
    for (final scan in scans) {
      if (_isSuccessfulScan(scan)) {
        hexesWithSuccess.add(hexKey(scan.latitude, scan.longitude));
      }
    }
    if (hexesWithSuccess.isEmpty) return scans;

    var suppressed = 0;
    final filtered = <RawScan>[];
    for (final scan in scans) {
      final hex = hexKey(scan.latitude, scan.longitude);
      if (_isDeadLikeScan(scan) && hexesWithSuccess.contains(hex)) {
        suppressed += 1;
        continue;
      }
      filtered.add(scan);
    }
    if (suppressed > 0) {
      _debugLog.info(
        'sync',
        'Suppressed $suppressed deadzone row(s) in hexes with successful scans ($source)',
      );
    }
    return filtered;
  }

  List<CoverageZone> _applyZoneDeadzonePrecedence(
    List<CoverageZone> zones, {
    required String source,
  }) {
    if (zones.isEmpty) return zones;
    final successfulZoneIds = zones
        .where((zone) => !zone.isDeadZone)
        .map((zone) => zone.id)
        .toSet();
    if (successfulZoneIds.isEmpty) return zones;
    var suppressed = 0;
    final filtered = <CoverageZone>[];
    for (final zone in zones) {
      if (zone.isDeadZone && successfulZoneIds.contains(zone.id)) {
        suppressed += 1;
        continue;
      }
      filtered.add(zone);
    }
    if (suppressed > 0) {
      _debugLog.info(
        'sync',
        'Suppressed $suppressed deadzone coverage row(s) in successful hexes ($source)',
      );
    }
    return filtered;
  }

  String? _connectedRadioMeshId8() {
    final mesh = _normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
    if (mesh.isEmpty) return null;
    return mesh.length >= 8 ? mesh.substring(0, 8) : mesh;
  }

  String? _safePublicRadioId(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;
    if (raw.contains(':') || raw.contains('-')) return null;
    final normalized = _normalizeHexId(raw);
    if (normalized.isEmpty) return null;
    // Avoid leaking BLE MAC-like IDs.
    if (normalized.length == 12) return null;
    return normalized.length >= 8 ? normalized.substring(0, 8) : normalized;
  }

  Future<void> _uploadPendingScans(WorkerApi api, List<RawScan> pending) async {
    final payload = pending
        .map(_toWorkerScanPayload)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final skipped = pending.length - payload.length;
    if (skipped > 0) {
      _debugLog.warn(
        'upload',
        'Skipped $skipped local scan(s) for upload due to missing/unsafe radioId',
      );
    }
    if (payload.isEmpty) return;
    _debugLog.info(
      'upload',
      'Uploading ${payload.length} local scan(s) to worker',
    );
    try {
      final uploaded = await api.uploadScans(payload);
      if (uploaded <= 0) return;
      final uploadedKeys = pending.map(_scanIdentity).toSet();
      rawScans = rawScans
          .map((scan) {
            if (!uploadedKeys.contains(_scanIdentity(scan))) return scan;
            return scan.copyWith(downloadedFromWorker: true);
          })
          .toList(growable: false);
      await _localStore.saveRawScans(rawScans);
      _debugLog.info(
        'upload',
        'Uploaded and marked $uploaded local scan(s) as synced',
      );
    } catch (e) {
      _debugLog.warn('upload', 'Upload failed, keeping local queue: $e');
    }
  }

  Map<String, dynamic>? _toWorkerScanPayload(RawScan scan) {
    final nodeId = _safePublicRadioId(scan.nodeId ?? '') ?? '';
    final nodeName = (scan.senderName ?? '').trim();
    final observerName = _resolveObserverNameForUpload(scan);
    final nodeEntry = <String, dynamic>{
      'nodeId': nodeId,
      if (nodeName.isNotEmpty) 'name': nodeName,
      if (observerName.isNotEmpty) 'observerName': observerName,
      'rssi': scan.rssi ?? 0.0,
      'snr': scan.snr ?? 0.0,
      if (scan.snrIn != null) 'snrIn': scan.snrIn,
    };

    final radioId = (scan.radioId ?? '').trim();
    final uploadRadioId = _safePublicRadioId(radioId);
    if (uploadRadioId == null) {
      return null;
    }
    return {
      'radioId': uploadRadioId,
      if (observerName.isNotEmpty) 'observerName': observerName,
      'timestamp': scan.effectiveTimestamp.toUtc().millisecondsSinceEpoch,
      'location': {
        'lat': scan.latitude,
        'lon': scan.longitude,
        if (scan.altitude != null) 'altitude': scan.altitude,
      },
      'nodes': nodeId.isNotEmpty ? [nodeEntry] : <Map<String, dynamic>>[],
    };
  }

  String _resolveObserverNameForUpload(RawScan scan) {
    final receiver = (scan.receiverName ?? '').trim();
    if (receiver.isNotEmpty) return receiver;

    final radioId = _normalizeHexId(scan.radioId ?? '');
    final observerId = _normalizeHexId(scan.observerId ?? '');
    final fromRadio = _bestContactNameForId(_radioContactsByPrefix, radioId);
    if (fromRadio != null && fromRadio.trim().isNotEmpty) {
      return fromRadio.trim();
    }
    final fromObserver = _bestContactNameForId(
      _radioContactsByPrefix,
      observerId,
    );
    if (fromObserver != null && fromObserver.trim().isNotEmpty) {
      return fromObserver.trim();
    }

    final connectedName = (_connectedRadioDisplayName ?? '').trim();
    final connectedMesh = _normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
    if (connectedName.isNotEmpty &&
        connectedMesh.isNotEmpty &&
        (_idsLikelySameDevice(radioId, connectedMesh) ||
            _idsLikelySameDevice(observerId, connectedMesh))) {
      return connectedName;
    }

    return '';
  }

  List<RawScan> _normalizeRawScans(List<RawScan> scans) {
    return scans.map(_normalizeRawScanIds).toList(growable: false);
  }

  List<RawScan> _sanitizeDeadzoneRadioIds(
    List<RawScan> scans,
    String? connectedRadioId,
  ) {
    final connected = _safePublicRadioId(connectedRadioId ?? '');
    return scans
        .map((scan) {
          final nodeId = (scan.nodeId ?? '').trim();
          final isDeadLike = nodeId.isEmpty || scan.rssi == null;
          if (!isDeadLike) return scan;
          final rowRadio = _safePublicRadioId(scan.radioId ?? '');
          final keep =
              connected != null && rowRadio != null && connected == rowRadio;
          if (keep) return scan;
          return RawScan(
            observerId: scan.observerId,
            nodeId: scan.nodeId,
            latitude: scan.latitude,
            longitude: scan.longitude,
            rssi: scan.rssi,
            snr: scan.snr,
            snrIn: scan.snrIn,
            altitude: scan.altitude,
            timestamp: scan.timestamp,
            receivedAt: scan.receivedAt,
            senderName: scan.senderName,
            receiverName: scan.receiverName,
            radioId: null,
            downloadedFromWorker: scan.downloadedFromWorker,
          );
        })
        .toList(growable: false);
  }

  List<CoverageZone> _sanitizeDeadzoneZoneRadioIds(
    List<CoverageZone> zones,
    String? connectedRadioId,
  ) {
    final connected = _safePublicRadioId(connectedRadioId ?? '');
    return zones
        .map((zone) {
          if (!zone.isDeadZone) return zone;
          final rowRadio = _safePublicRadioId(zone.radioId ?? '');
          final keep =
              connected != null && rowRadio != null && connected == rowRadio;
          if (keep) return zone;
          return CoverageZone(
            id: zone.id,
            centerLat: zone.centerLat,
            centerLng: zone.centerLng,
            radiusMeters: zone.radiusMeters,
            avgRssi: zone.avgRssi,
            avgSnr: zone.avgSnr,
            scanCount: zone.scanCount,
            lastScanned: zone.lastScanned,
            isDeadZone: zone.isDeadZone,
            polygon: zone.polygon,
            radioId: null,
          );
        })
        .toList(growable: false);
  }

  RawScan _normalizeRawScanIds(RawScan scan) {
    return RawScan(
      observerId: _safePublicRadioId(scan.observerId ?? ''),
      nodeId: _safePublicRadioId(scan.nodeId ?? ''),
      latitude: scan.latitude,
      longitude: scan.longitude,
      rssi: scan.rssi,
      snr: scan.snr,
      snrIn: scan.snrIn,
      altitude: scan.altitude,
      timestamp: scan.timestamp,
      receivedAt: scan.receivedAt,
      senderName: scan.senderName,
      receiverName: scan.receiverName,
      radioId: _safePublicRadioId(scan.radioId ?? ''),
      downloadedFromWorker: scan.downloadedFromWorker,
    );
  }

  bool _idsLikelySameDevice(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    if (a.startsWith(b) || b.startsWith(a)) return true;
    final a8 = a.length >= 8 ? a.substring(0, 8) : a;
    final b8 = b.length >= 8 ? b.substring(0, 8) : b;
    return a8 == b8;
  }

  String _extractPrintableAscii(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      if (b >= 32 && b <= 126) {
        sb.writeCharCode(b);
      }
    }
    return sb.toString();
  }

  String? _extractSelfInfoDisplayName(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    // MeshCore self-info often contains binary-looking ASCII then a '$' marker
    // before the human-readable radio name.
    var candidate = trimmed;
    final markerIndex = candidate.lastIndexOf(r'$');
    if (markerIndex >= 0 && markerIndex + 1 < candidate.length) {
      candidate = candidate.substring(markerIndex + 1);
    }
    candidate = candidate.trim();
    if (candidate.isEmpty) return null;

    // Keep common readable name characters and collapse spacing.
    candidate = candidate
        .replaceAll(RegExp(r'[^A-Za-z0-9 ._\-]'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    candidate = _cleanRadioDisplayName(candidate);
    if (candidate.length < 3) return null;
    return candidate;
  }

  Set<String> _nameTokens(String value) {
    return value
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.length >= 3)
        .toSet();
  }

  String _selectedBleDeviceName() {
    final selectedId = bleSelectedDeviceId;
    if (selectedId == null || selectedId.isEmpty) return '';
    final fromMap = _bleDeviceNamesById[selectedId];
    if (fromMap != null && fromMap.isNotEmpty) return fromMap;
    for (final label in bleScanDevices) {
      final suffix = '[$selectedId]';
      if (label.endsWith(suffix)) {
        return label.substring(0, label.length - suffix.length).trim();
      }
    }
    return '';
  }

  String _cleanRadioDisplayName(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return value;
    value = value
        .replaceAll(RegExp(r'\bble\b', caseSensitive: false), '')
        .trim();
    value = value.replaceAll(RegExp(r'\s{2,}'), ' ');
    if (value == '-' || value == '_' || value == '()') return '';
    return value;
  }

  void _pruneSelfContact(Map<String, String> contacts) {
    if (contacts.isEmpty) return;
    final mesh = _normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
    if (mesh.isNotEmpty && contacts.remove(mesh) != null) {
      _debugLog.info('contacts', 'Removed self contact entry for mesh=$mesh');
      return;
    }

    final selectedTokens = _nameTokens(_selectedBleDeviceName().toLowerCase());
    if (selectedTokens.isEmpty) return;
    String? bestKey;
    var bestScore = 0;
    for (final entry in contacts.entries) {
      final nameTokens = _nameTokens(entry.value.toLowerCase());
      if (nameTokens.isEmpty) continue;
      var score = 0;
      for (final token in selectedTokens) {
        if (token.length >= 4 && nameTokens.contains(token)) {
          score += 1;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        bestKey = entry.key;
      }
    }
    if (bestKey != null && bestScore >= 2) {
      final removedName = contacts.remove(bestKey);
      if (removedName != null) {
        _debugLog.info(
          'contacts',
          'Removed likely self contact by name match key=$bestKey name=$removedName score=$bestScore',
        );
      }
    }
  }

  void _applyKnownContactsBackfill() {
    if (_radioContactsByPrefix.isEmpty || rawScans.isEmpty) return;
    final updated = _backfillScanNamesFromContacts(_radioContactsByPrefix);
    if (updated > 0) {
      _debugLog.info(
        'contacts',
        'Applied cached contact names after sync: updated $updated field(s)',
      );
    }
  }

  Future<void> toggleBleScan() async {
    if (!await _ensureBleAvailable(context: 'ble_scan')) {
      return;
    }
    if (bleScanning) {
      _debugLog.info('ble_scan', 'Auto scan paused');
      bleScanning = false;
      bleScanStatus = 'idle';
      _bleAutoScanTimer?.cancel();
      bleNextScanCountdown = null;
      _autoScanRemainingSeconds = 0;
      _smartScanPausedForRecentCoverage = false;
      _smartScanPausedZoneId = null;
      notifyListeners();
      return;
    }

    if (!bleConnected) {
      await connectBle();
      if (!bleConnected) return;
    }

    bleScanning = true;
    _debugLog.info('ble_scan', 'Auto scan started');
    bleScanStatus = 'idle';
    notifyListeners();
    await _runAutoScanCycle();
    if (!bleScanning || !bleConnected || !_transport.isConnected) {
      _debugLog.warn(
        'ble_scan',
        'Auto scan loop not started because BLE is no longer connected',
      );
      return;
    }
    _startAutoScanLoop();
  }

  Future<void> forceBleScan() async {
    if (!await _ensureBleAvailable(context: 'ble_discover')) {
      return;
    }
    await runNodeDiscover();
  }

  Future<void> _attemptAutoReconnect({String? reason}) async {
    if (_autoReconnectInProgress || _manualBleDisconnectRequested) return;
    if (bleSelectedDeviceId == null || bleSelectedDeviceId!.isEmpty) return;
    _autoReconnectInProgress = true;
    try {
      _debugLog.info(
        'ble',
        'Attempting auto-reconnect after disconnect'
            '${reason == null || reason.isEmpty ? '' : ' ($reason)'}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await connectBle();
      if (!bleConnected || !_transport.isConnected) {
        _debugLog.warn('ble', 'Auto-reconnect failed');
        return;
      }
      if (_resumeAutoScanAfterReconnect) {
        _resumeAutoScanAfterReconnect = false;
        bleScanning = true;
        bleScanStatus = 'idle';
        notifyListeners();
        await _runAutoScanCycle();
        if (bleScanning && bleConnected && _transport.isConnected) {
          _startAutoScanLoop();
        }
      }
    } finally {
      _autoReconnectInProgress = false;
    }
  }

  void _startAutoScanLoop() {
    _bleAutoScanTimer?.cancel();
    _debugLog.debug(
      'ble_scan',
      'Auto scan loop interval=${settings.scanIntervalSeconds}s',
    );
    _autoScanRemainingSeconds = settings.scanIntervalSeconds;
    bleNextScanCountdown = _autoScanRemainingSeconds;

    _bleAutoScanTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (!bleScanning) {
        timer.cancel();
        return;
      }
      if (_smartScanPausedForRecentCoverage) {
        bleNextScanCountdown = _autoScanRemainingSeconds;
        notifyListeners();
        return;
      }
      _autoScanRemainingSeconds -= 1;
      if (_autoScanRemainingSeconds <= 0) {
        _autoScanRemainingSeconds = settings.scanIntervalSeconds;
        bleNextScanCountdown = _autoScanRemainingSeconds;
        notifyListeners();
        if (!bleBusy) {
          await _runAutoScanCycle();
        }
        return;
      }
      bleNextScanCountdown = _autoScanRemainingSeconds;
      notifyListeners();
    });
  }

  Future<void> _runAutoScanCycle() async {
    final decision = _evaluateSmartScanDecision();
    if (decision.skip) {
      _smartScanPausedForRecentCoverage = true;
      _smartScanPausedZoneId = decision.zoneId;
      bleScanStatus = 'done';
      bleStatus = 'Smart scan skipped: recently covered';
      bleLastDiscoverError = null;
      _debugLog.info(
        'smart_scan',
        'Skipped auto scan for zone=${decision.zoneId} reason=${decision.reason}',
      );
      notifyListeners();
      return;
    }
    _smartScanPausedForRecentCoverage = false;
    _smartScanPausedZoneId = decision.zoneId;
    _autoScanRemainingSeconds = settings.scanIntervalSeconds;
    bleNextScanCountdown = _autoScanRemainingSeconds;
    await runNodeDiscover();
  }

  Future<void> _onObserverZoneMaybeChanged() async {
    if (!bleScanning || !bleConnected || bleBusy) return;
    if (!_smartScanPausedForRecentCoverage) return;

    final decision = _evaluateSmartScanDecision();
    if (decision.skip) {
      _smartScanPausedZoneId = decision.zoneId;
      return;
    }

    final fromZone = _smartScanPausedZoneId;
    _smartScanPausedForRecentCoverage = false;
    _smartScanPausedZoneId = decision.zoneId;
    _autoScanRemainingSeconds = settings.scanIntervalSeconds;
    bleNextScanCountdown = _autoScanRemainingSeconds;
    _debugLog.info(
      'smart_scan',
      'Left recent-coverage zone=${fromZone ?? 'unknown'}; '
          'triggering immediate scan for zone=${decision.zoneId ?? 'unknown'} '
          'reason=${decision.reason}',
    );
    notifyListeners();
    await _runAutoScanCycle();
  }

  _SmartScanDecision _evaluateSmartScanDecision() {
    if (!settings.smartScanEnabled || settings.smartScanDays < 1) {
      return const _SmartScanDecision(skip: false, reason: 'disabled');
    }
    final lat = deviceLatitude;
    final lng = deviceLongitude;
    if (lat == null || lng == null) {
      return const _SmartScanDecision(skip: false, reason: 'no_location');
    }
    final zoneId = hexKey(lat, lng);
    final cutoff = DateTime.now().subtract(
      Duration(days: settings.smartScanDays),
    );

    final zoneIsDead = coverageZones.any((z) => z.id == zoneId && z.isDeadZone);
    if (zoneIsDead) {
      return _SmartScanDecision(
        skip: false,
        zoneId: zoneId,
        reason: 'dead_zone_forced_scan',
      );
    }

    var hasRecentSuccess = false;
    for (final scan in rawScans) {
      if (hexKey(scan.latitude, scan.longitude) != zoneId) continue;
      if (_isDeadLikeScan(scan)) continue;
      if (scan.effectiveTimestamp.isAfter(cutoff)) {
        hasRecentSuccess = true;
        break;
      }
    }

    if (!hasRecentSuccess) {
      return _SmartScanDecision(
        skip: false,
        zoneId: zoneId,
        reason: 'stale_or_missing_coverage',
      );
    }
    return _SmartScanDecision(
      skip: true,
      zoneId: zoneId,
      reason: 'recent_coverage',
    );
  }

  void _rebuildDerivedData({bool skipZones = false}) {
    if (!skipZones) {
      coverageZones = aggregateScansToZones(rawScans);
    }
    nodes = extractNodes(rawScans);
    scanResults = convertToScanResults(rawScans)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  Future<void> _startDeviceLocationTracking() async {
    try {
      _debugLog.info('location', 'Starting OS location tracking');
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        deviceLocationStatus = 'Location services disabled';
        _debugLog.warn('location', deviceLocationStatus);
        notifyListeners();
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        deviceLocationStatus = 'Location permission denied';
        _debugLog.warn('location', deviceLocationStatus);
        notifyListeners();
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        deviceLocationStatus = 'Location permission denied forever';
        _debugLog.warn('location', deviceLocationStatus);
        notifyListeners();
        return;
      }

      deviceLocationStatus = 'Location active';
      notifyListeners();

      try {
        final initial = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
          ),
        ).timeout(const Duration(seconds: 8));
        _applyDevicePosition(initial, source: 'current');
      } catch (e) {
        _debugLog.warn('location', 'Initial location fetch failed: $e');
        await _tryIpFallbackLocation();
      }

      await _locationSubscription?.cancel();
      _locationPollTimer?.cancel();
      _locationSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            ),
          ).listen(
            (position) => _applyDevicePosition(position, source: 'stream'),
            onError: (Object e) {
              deviceLocationStatus = 'Location stream error';
              _debugLog.error('location', 'Location stream error: $e');
              notifyListeners();
            },
          );
      deviceLocationStatus = 'Waiting for location fix...';
      notifyListeners();
      _locationPollTimer = Timer.periodic(
        const Duration(seconds: 12),
        (_) => _pollLocationFallback(),
      );
      _debugLog.info('location', 'Location tracking started');
    } catch (e) {
      deviceLocationStatus = 'Location unavailable';
      _debugLog.error('location', 'Location setup failed: $e');
      notifyListeners();
    }
  }

  void _applyDevicePosition(Position position, {required String source}) {
    deviceLatitude = position.latitude;
    deviceLongitude = position.longitude;
    deviceAltitude = position.altitude;
    deviceLocationAt = DateTime.now();
    deviceLocationStatus = 'Location active';
    _debugLog.info(
      'location',
      '$source lat=${position.latitude.toStringAsFixed(6)} '
          'lng=${position.longitude.toStringAsFixed(6)} '
          'alt=${position.altitude.toStringAsFixed(1)}',
    );
    notifyListeners();
    unawaited(_onObserverZoneMaybeChanged());
  }

  Future<void> _pollLocationFallback() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 0,
        ),
      ).timeout(const Duration(seconds: 6));
      _applyDevicePosition(pos, source: 'poll');
    } catch (e) {
      _debugLog.debug('location', 'Fallback poll no fix yet: $e');
      await _tryIpFallbackLocation();
    }
  }

  Future<void> _refreshLocationForDiscoverResponse() async {
    if (_discoverLocationRefreshInFlight) return;
    final now = DateTime.now();
    if (_lastDiscoverLocationRefreshAt != null &&
        now.difference(_lastDiscoverLocationRefreshAt!) <
            const Duration(seconds: 1)) {
      return;
    }
    _discoverLocationRefreshInFlight = true;
    _lastDiscoverLocationRefreshAt = now;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        ),
      ).timeout(const Duration(seconds: 2));
      _applyDevicePosition(pos, source: 'discover');
    } catch (_) {
      // Keep discover path non-blocking; periodic/stream updates still apply.
    } finally {
      _discoverLocationRefreshInFlight = false;
    }
  }

  bool get _isLinuxDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  Future<void> _tryIpFallbackLocation() async {
    if (!_isLinuxDesktop) return;
    final now = DateTime.now();
    if (_lastIpFallbackAt != null &&
        now.difference(_lastIpFallbackAt!) < const Duration(minutes: 2)) {
      return;
    }
    _lastIpFallbackAt = now;
    try {
      final res = await http
          .get(
            Uri.parse(
              'http://ip-api.com/json/?fields=status,lat,lon,city,regionName,country',
            ),
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body);
      if (data is! Map<String, dynamic>) return;
      if (data['status'] != 'success') return;
      final lat = (data['lat'] as num?)?.toDouble();
      final lon = (data['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) return;
      deviceLatitude = lat;
      deviceLongitude = lon;
      deviceAltitude = null;
      deviceLocationAt = DateTime.now();
      deviceLocationStatus = 'Location fallback active';
      _debugLog.info(
        'location',
        'ip-fallback lat=${lat.toStringAsFixed(6)} lng=${lon.toStringAsFixed(6)}',
      );
      notifyListeners();
    } catch (e) {
      _debugLog.debug('location', 'IP fallback failed: $e');
    }
  }

  @override
  void dispose() {
    _debugLog.info('app_state', 'Disposing app state');
    _locationSubscription?.cancel();
    _locationPollTimer?.cancel();
    _bleAutoScanTimer?.cancel();
    _bleCountdownTimer?.cancel();
    _periodicSyncTimer?.cancel();
    unawaited(_transport.dispose());
    super.dispose();
  }

  void _configurePeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
    if (settings.forceOffline) {
      _debugLog.info('sync', 'Periodic sync disabled (offline mode enabled)');
      return;
    }
    final configured = settings.uploadBatchIntervalMinutes;
    final intervalMinutes = configured < 30
        ? 30
        : (configured > 1440 ? 1440 : configured);
    _periodicSyncTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_maybeRunPeriodicSync(intervalMinutes));
    });
    _debugLog.info(
      'sync',
      'Periodic sync scheduled interval=${intervalMinutes}m',
    );
  }

  Future<void> _maybeRunPeriodicSync(int intervalMinutes) async {
    if (loading || syncing || settings.forceOffline) return;
    final interval = Duration(minutes: intervalMinutes);
    var internetNow = _estimatedInternetNowUtc();
    if (internetNow == null) {
      await _refreshInternetTimeAnchor();
      internetNow = _estimatedInternetNowUtc();
    }
    if (internetNow == null) {
      _debugLog.warn('sync', 'Periodic sync waiting for internet time anchor');
      return;
    }

    final last = _lastPeriodicSyncInternetUtc;
    if (last != null && internetNow.difference(last) < interval) {
      return;
    }

    _debugLog.info(
      'sync',
      'Periodic sync trigger (internet time) interval=${intervalMinutes}m',
    );
    await syncFromWorker();
  }

  void _captureInternetTimeAnchor(DateTime? serverUtc) {
    if (serverUtc == null) return;
    _internetTimeAnchorUtc = serverUtc.toUtc();
    _internetTimeAnchorElapsed = _monotonicClock.elapsed;
    _debugLog.debug(
      'sync',
      'Internet time anchor updated: ${_internetTimeAnchorUtc!.toIso8601String()}',
    );
  }

  DateTime? _estimatedInternetNowUtc() {
    final anchorUtc = _internetTimeAnchorUtc;
    final anchorElapsed = _internetTimeAnchorElapsed;
    if (anchorUtc == null || anchorElapsed == null) return null;
    final delta = _monotonicClock.elapsed - anchorElapsed;
    return anchorUtc.add(delta);
  }

  Future<void> _refreshInternetTimeAnchor() async {
    if (_internetTimeRefreshInFlight || settings.forceOffline) return;
    _internetTimeRefreshInFlight = true;
    try {
      final api = WorkerApi(
        AppConfig.deployedWorkerUrl,
        fallbackBaseUrl: AppConfig.fallbackWorkerUrl,
      );
      final serverNow = await api.fetchServerUtcNow();
      _captureInternetTimeAnchor(serverNow);
    } catch (e) {
      _debugLog.debug('sync', 'Internet time refresh failed: $e');
    } finally {
      _internetTimeRefreshInFlight = false;
    }
  }

  void clearDebugLogs() {
    _debugLog.clear();
  }

  Future<void> clearScanCache() async {
    _debugLog.info('cache', 'Clearing local scan cache');
    await _localStore.clearRawScans();
    rawScans = const [];
    coverageZones = const [];
    nodes = const [];
    scanResults = const [];
    notifyListeners();
  }

  Future<int> downloadOfflineMapTiles() async {
    final observer = currentObserverPosition;
    if (observer == null) {
      throw StateError(
        'No current observer location available for tile download',
      );
    }
    final count = await TileCacheService.prefetchAround(
      centerLat: observer.$1,
      centerLng: observer.$2,
      urlTemplates: _offlineTileTemplates,
      radiusMiles: 5,
      minZoom: 11,
      maxZoom: 15,
      maxTiles: 900,
    );
    _debugLog.info(
      'tile_cache',
      'Prefetched $count tile(s) around '
          'lat=${observer.$1.toStringAsFixed(6)} '
          'lng=${observer.$2.toStringAsFixed(6)}',
    );
    return count;
  }

  Future<void> clearOfflineMapTiles() async {
    await TileCacheService.clearCache();
    _debugLog.info('tile_cache', 'Offline map tile cache cleared');
  }

  Future<void> _applyCompanionLocationPolicyFromSettings() async {
    if (!bleConnected || !_transport.isConnected) return;
    final policy = settings.updateRadioPosition
        ? _advertLocationPolicyCompanion
        : _advertLocationPolicyDisabled;
    try {
      await _bleProtocol.run(
        _protocol.setOtherParams(
          allowTelemetryFlags: _otherParamsAllowTelemetryFlags,
          advertLocationPolicy: policy,
          multiAcks: _otherParamsMultiAcks,
        ),
      );
      _debugLog.info(
        'radio_position',
        'Applied companion coordinate policy=${settings.updateRadioPosition ? 'on' : 'off'}',
      );
    } catch (e) {
      _debugLog.warn(
        'radio_position',
        'Failed to apply companion coordinate policy: $e',
      );
    }
  }

  Future<void> deleteConnectedRadioData() async {
    if (_deleteInProgress) return;

    final radioId = _connectedRadioMeshId8();
    final publicKey = _connectedRadioPublicKeyHex;
    if (radioId == null || radioId.isEmpty || publicKey == null) {
      throw StateError('Connected radio identity is unavailable');
    }
    if (settings.forceOffline) {
      throw StateError('Delete requires online mode');
    }
    if (!bleConnected) {
      throw StateError('Connect to your radio first');
    }

    _deleteInProgress = true;
    notifyListeners();
    try {
      final api = WorkerApi(
        AppConfig.deployedWorkerUrl,
        fallbackBaseUrl: AppConfig.fallbackWorkerUrl,
      );
      final challengeRes = await api.requestDeleteChallenge(
        radioId: radioId,
        publicKeyHex: publicKey,
      );
      final signatureHex = await _signDeleteChallenge(
        challengeRes.challenge,
        publicKeyHex: publicKey,
      );
      final deleteRes = await api.submitDeleteRequest(
        radioId: radioId,
        publicKeyHex: publicKey,
        challenge: challengeRes.challenge,
        signatureHex: signatureHex,
      );

      final next = rawScans
          .where(
            (scan) => (_safePublicRadioId(scan.radioId ?? '') ?? '') != radioId,
          )
          .toList(growable: false);
      final removedLocal = rawScans.length - next.length;
      rawScans = next;
      _rebuildDerivedData();
      await _localStore.saveRawScans(rawScans);

      _debugLog.info(
        'delete',
        'Delete completed for radio=$radioId '
            'd1Deleted=${deleteRes.d1Deleted} '
            'pendingRemoved=${deleteRes.pendingRemoved} '
            'csvRowsRemoved=${deleteRes.csvRowsRemoved} '
            'localRemoved=$removedLocal',
      );
    } finally {
      _deleteInProgress = false;
      notifyListeners();
    }
  }

  Future<String> _signDeleteChallenge(
    String challenge, {
    required String publicKeyHex,
  }) async {
    if (!_transport.isConnected || !bleConnected) {
      throw StateError('BLE is not connected');
    }
    final payload = Uint8List.fromList(utf8.encode(challenge));
    const chunkSize = 128;
    _debugLog.info(
      'delete',
      'Starting radio-sign challenge flow bytes=${payload.length} keyPrefix=${publicKeyHex.substring(0, 8)}',
    );

    final signStartFuture = _awaitSignFrame(
      expectCode: respCodeSignStart,
      stage: 'sign_start',
    );
    _debugLog.debug('delete', 'sign_start -> send');
    await _bleProtocol.run(_protocol.signStart());
    final signStartFrame = await signStartFuture;
    if (signStartFrame.length < 6) {
      throw StateError('Invalid sign_start response length');
    }
    final maxSignDataLen =
        signStartFrame[2] |
        (signStartFrame[3] << 8) |
        (signStartFrame[4] << 16) |
        (signStartFrame[5] << 24);
    if (payload.length > maxSignDataLen) {
      throw StateError(
        'Delete challenge too long for radio signer (${payload.length} > $maxSignDataLen)',
      );
    }
    _debugLog.debug(
      'delete',
      'sign_start <- ok maxSignDataLen=$maxSignDataLen payloadLen=${payload.length}',
    );

    var offset = 0;
    var chunkIndex = 0;
    while (offset < payload.length) {
      final end = (offset + chunkSize) < payload.length
          ? offset + chunkSize
          : payload.length;
      final chunk = Uint8List.fromList(payload.sublist(offset, end));
      chunkIndex += 1;
      _debugLog.debug(
        'delete',
        'sign_data[$chunkIndex] -> send bytes=${chunk.length} range=$offset..${end - 1}',
      );
      final okFuture = _awaitSignFrame(
        expectCode: respCodeOk,
        stage: 'sign_data',
      );
      await _bleProtocol.run(_protocol.signData(chunk));
      await okFuture;
      _debugLog.debug('delete', 'sign_data[$chunkIndex] <- ok');
      offset = end;
    }

    final signatureFuture = _awaitSignFrame(
      expectCode: respCodeSignature,
      stage: 'sign_finish',
    );
    _debugLog.debug('delete', 'sign_finish -> send');
    await _bleProtocol.run(_protocol.signFinish());
    final signatureFrame = await signatureFuture;
    if (signatureFrame.length < 65) {
      throw StateError('Invalid signature response length');
    }
    final signature = Uint8List.fromList(signatureFrame.sublist(1, 65));
    final signatureHex = _bytesToHex(signature);
    _debugLog.info('delete', 'Radio challenge signature received');
    return signatureHex;
  }

  Future<Uint8List> _awaitSignFrame({
    required int expectCode,
    required String stage,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final frame = await _transport.inbound
        .firstWhere((data) {
          if (data.isEmpty) return false;
          final code = data[0];
          if (code == expectCode || code == respCodeErr) {
            return true;
          }
          _debugLog.debug(
            'delete',
            '$stage waiting: saw unrelated frame code=0x${code.toRadixString(16)} len=${data.length}',
          );
          return false;
        })
        .timeout(timeout);
    if (frame[0] == respCodeErr) {
      final errCode = frame.length > 1 ? frame[1] : -1;
      _debugLog.error('delete', '$stage <- err code=$errCode');
      throw StateError('Radio signing failed at $stage (err=$errCode)');
    }
    _debugLog.debug(
      'delete',
      '$stage <- frame code=0x${frame[0].toRadixString(16)} len=${frame.length}',
    );
    return frame;
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  }
}

class _SmartScanDecision {
  const _SmartScanDecision({
    required this.skip,
    required this.reason,
    this.zoneId,
  });

  final bool skip;
  final String reason;
  final String? zoneId;
}
