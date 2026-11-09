import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/config/app_config.dart';
import 'package:mesh_utility/src/services/all_days_load_guard.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/battery_optimization.dart';
import 'package:mesh_utility/src/services/scan_foreground_mode.dart';
import 'package:mesh_utility/src/services/radio_id_utils.dart';
import 'package:mesh_utility/src/services/scan_data_utils.dart';
import 'package:mesh_utility/src/services/location_service.dart';
import 'package:mesh_utility/src/services/coverage_overview.dart';
import 'package:mesh_utility/src/services/map_camera.dart';
import 'package:mesh_utility/src/services/sync_service.dart';
import 'package:mesh_utility/src/services/app_i18n.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/hex_name_index.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/mesh_stage_log.dart';
import 'package:mesh_utility/src/services/last_known_fix_store.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/mesh_database_path.dart';
import 'package:mesh_utility/src/services/off_ui.dart';
import 'package:mesh_utility/src/services/scan_cache_area.dart';
import 'package:mesh_utility/src/services/scan_cache_service.dart';
import 'package:mesh_utility/src/services/persisted_history_loader.dart';
import 'package:mesh_utility/src/services/contact_store.dart';
import 'package:mesh_utility/src/models/local_contact.dart';
import 'package:mesh_utility/src/platform/local_contacts_supported.dart';
import 'package:mesh_utility/src/services/reax_database.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/src/services/tile_cache_service.dart';
import 'package:mesh_utility/src/services/worker_api.dart';
import 'package:mesh_utility/transport/ble_transport.dart';
import 'package:mesh_utility/transport/contact_sync.dart';
import 'package:mesh_utility/transport/protocol.dart';
import 'package:mesh_utility/transport/transport.dart';
import 'package:universal_ble/universal_ble.dart';

class AppState extends ChangeNotifier {
  static const int _otherParamsAllowTelemetryFlags = 0;
  static const int _otherParamsMultiAcks = 0;
  static const int _advertLocationPolicyDisabled = 0;
  static const int _advertLocationPolicyCompanion = 1;
  static const List<String> _offlineTileTemplates = [
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
  ];

  AppState({
    required SettingsStore settingsStore,
    required LocalStore localStore,
    required Transport transport,
    AppDebugLogService? debugLogService,
    CoverageOverviewCache? coverageOverviewCache,
    WorkerApi Function()? coverageOverviewApi,
  }) : _settingsStore = settingsStore,
       _localStore = localStore,
       _transport = transport,
       _debugLog = debugLogService ?? AppDebugLogService.instance,
       _overviewCache = coverageOverviewCache ?? CoverageOverviewCache(),
       _coverageOverviewApi = coverageOverviewApi {
    if (_transport is BleTransport) {
      final ble = _transport;
      ble.onRequestPin = (deviceId) async {
        _debugLog.info('ble', 'PIN/passkey requested for $deviceId');
        if (_silentBleConnectDepth > 0) {
          _debugLog.warn(
            'ble',
            'Skipping PIN prompt during background reconnect for $deviceId',
          );
          return null;
        }
        if (onBlePinRequest == null) {
          _debugLog.warn('ble', 'No UI PIN handler registered for $deviceId');
          return null;
        }
        return onBlePinRequest!(deviceId);
      };
      ble.onScanResult = (deviceId, deviceName) {
        final changed = _upsertBleScanDevice(
          deviceId: deviceId,
          deviceName: deviceName,
        );
        if (changed) {
          notifyListeners();
        }
        if (kIsWeb &&
            !bleConnected &&
            !bleConnecting &&
            _webAutoConnectAttemptedDeviceId != deviceId) {
          _webAutoConnectAttemptedDeviceId = deviceId;
          _debugLog.info(
            'ble',
            'Web picker returned device; selecting and auto-connecting: $deviceId',
          );
          selectBleDevice(deviceId);
        }
      };
      ble.onConnectionStateChanged =
          ({required bool connected, String? deviceId, String? reason}) {
            if (connected) {
              return;
            }
            final wasScanning = bleScanning;
            if (!bleConnected && !bleConnecting) {
              _signalContactSyncLinkClosed();
              return;
            }
            bleConnected = false;
            bleConnecting = false;
            bleBusy = false;
            bleScanning = false;
            bleScanStatus = 'idle';
            _bleAutoScanTimer?.cancel();
            _bleCountdownTimer?.cancel();
            _resetAutoScanSchedule();
            _smartScanPausedForRecentCoverage = false;
            _smartScanPausedZoneId = null;
            _connectedRadioMeshIdPrefix = null;
            _connectedRadioPublicKeyHex = null;
            _connectedRadioDisplayName = null;
            _lastSelfInfoHex = null;
            _lastSelfInfoText = null;
            _sessionRadioContacts.clear();
            _sessionRadioContactTypes.clear();
            _invalidateSessionContactLookup();
            // An in-flight contact sync owns the final status. Clearing it
            // here would replace "Bluetooth disconnected" with idle.
            if (!_contactSyncInFlight) {
              contactsSyncProgress = ContactSyncProgress.idle;
            }
            _stopPassiveAdvertListener();
            bleStatus = 'BLE disconnected';
            _resumeAutoScanAfterReconnect = wasScanning || _scanLoopWanted;
            _debugLog.warn(
              'ble',
              'Connection lost device=${deviceId ?? 'unknown'} reason=${reason ?? 'unknown'}',
            );
            _syncAndroidScanForeground();
            notifyListeners();
            _signalContactSyncLinkClosed();
            if (!_manualBleDisconnectRequested && !kIsWeb) {
              if (_scanLoopWanted) {
                _armScanLoopReconnect(reason: reason);
              } else {
                unawaited(_attemptAutoReconnect(reason: reason));
              }
            }
          };
      _bleAvailabilitySubscription = UniversalBle.availabilityStream.listen((
        state,
      ) {
        if (state == AvailabilityState.poweredOn) return;
        unawaited(
          _handleBleUnavailableState(
            state: state,
            context: 'ble_state',
            prompt: true,
          ),
        );
      });
    }
    if (kIsWeb) {
      bleStatus = 'BLE ready (web)';
    }
    _syncService.addListener(notifyListeners);
    _locationService.addListener(notifyListeners);
    _locationService.onPositionChanged = (lat, lng) {
      unawaited(_rememberDeviceFix(lat, lng));
      final zoneId = hexKey(lat, lng);
      if (zoneId == _lastObservedZoneId) return;
      _lastObservedZoneId = zoneId;
      unawaited(_onObserverZoneMaybeChanged());
    };
  }

  final SettingsStore _settingsStore;
  final LocalStore _localStore;
  final ContactStore _contactStore = ContactStore();
  final Transport _transport;
  final AppDebugLogService _debugLog;

  late final TransportProtocol _bleProtocol = TransportProtocol(_transport);
  final ProtocolCommandRegistry _protocol = const ProtocolCommandRegistry();

  final SyncService _syncService = SyncService();
  final AllDaysLoadGuard _allDaysGuard = AllDaysLoadGuard();
  AppSettings settings = AppSettings.defaults;
  bool loading = true;
  int _historyLoadToken = 0;
  int _derivedGeneration = 0;
  bool _lastWorkerSyncSucceeded = false;
  bool _workerSyncStarting = false;
  String? historyLoadLabel;
  bool get syncing => _syncService.syncing;
  String? get error => _syncService.error;
  DateTime? get lastSyncAt => _syncService.lastSyncAt;
  int get lastSyncScanCount => _syncService.lastSyncScanCount;

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

  /// Unit tests skip the Bluetooth availability check and mark the link up.
  @visibleForTesting
  bool debugBleReady = false;

  /// Unit tests replace the radio discover write. The countdown must move
  /// before this future completes.
  @visibleForTesting
  Future<void> Function()? debugDiscoverSend;

  /// Anchor passed to the last normal or forced schedule.
  @visibleForTesting
  DateTime? get debugLastAutoScanTriggerAt => _lastAutoScanTriggerAt;

  /// When the next auto-scan cycle is due.
  @visibleForTesting
  DateTime? get debugNextAutoScanDueAt => _nextAutoScanDueAt;

  int bleLastDiscoverCount = 0;
  String? bleLastDiscoverError;
  List<String> bleScanDevices = const [];
  String? bleSelectedDeviceId;
  final LocationService _locationService = LocationService();
  final LastKnownFixStore _lastKnownFixStore = LastKnownFixStore();
  final ScanCacheService _scanCache = ScanCacheService();
  double? _cachedFixLat;
  double? _cachedFixLng;
  bool _startupSyncFinished = false;
  bool _cachePruneRunning = false;
  bool _expandDuringSync = false;
  bool _pruneAfterSync = false;
  bool _localStampDirty = false;
  bool _travelFetchRunning = false;
  String? _outsideDivisionKey;
  bool _outsideDivisionValue = false;
  double? get deviceLatitude => _locationService.deviceLatitude;
  double? get deviceLongitude => _locationService.deviceLongitude;
  double? get deviceAltitude => _locationService.deviceAltitude;
  DateTime? get deviceLocationAt => _locationService.deviceLocationAt;
  String get deviceLocationStatus => _locationService.deviceLocationStatus;
  Timer? _bleCountdownTimer;
  Timer? _bleAutoScanTimer;
  StreamSubscription<Uint8List>? _passiveAdvertSubscription;
  StreamSubscription<AvailabilityState>? _bleAvailabilitySubscription;
  String? _lastObservedZoneId;
  final Map<String, String> _radioContactsByPrefix = {};
  final Map<String, String> _sessionRadioContacts = {};
  final Map<String, int> _sessionRadioContactTypes = {};
  ContactSyncProgress contactsSyncProgress = ContactSyncProgress.idle;
  Completer<void>? _contactSyncLinkClosed;

  bool get _contactSyncInFlight =>
      _contactSyncLinkClosed != null && !_contactSyncLinkClosed!.isCompleted;

  void _signalContactSyncLinkClosed() {
    final pending = _contactSyncLinkClosed;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  final Map<String, String> _bleDeviceNamesById = {};
  static const String _knownBleDeviceFallbackName = 'Known Device';
  bool _manualBleDisconnectRequested = false;
  String? _webAutoConnectAttemptedDeviceId;

  void _setBleUnavailableStatus({String context = 'ble'}) {
    if (_scanLoopWanted) {
      _abandonScanLoopReconnect('bluetooth unsupported');
    }
    bleConnected = false;
    bleConnecting = false;
    bleBusy = false;
    bleScanning = false;
    bleDeviceScanInProgress = false;
    bleScanStatus = 'idle';
    _stopPassiveAdvertListener();
    bleStatus = _bleUnavailableStatusMessage();
    _debugLog.info(context, bleStatus);
    _signalContactSyncLinkClosed();
    _syncAndroidScanForeground();
    notifyListeners();
  }

  String _bleUnavailableStatusMessage() {
    if (!kIsWeb) return 'BLE unavailable on this platform';
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'Web BLE unavailable on this iPhone browser/runtime. '
          'If you are already in Bluefy, update Bluefy and allow Bluetooth '
          'permission for this site, then retry scan/connect.';
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

  String _bleUnavailableStateMessage(AvailabilityState state) {
    switch (state) {
      case AvailabilityState.poweredOff:
        return 'Bluetooth is off. Turn Bluetooth on, then try again.';
      case AvailabilityState.unauthorized:
        return 'Bluetooth permission denied. Allow Bluetooth access, then try again.';
      case AvailabilityState.resetting:
        return 'Bluetooth is resetting. Please wait and retry.';
      case AvailabilityState.unsupported:
        return _bleUnavailableStatusMessage();
      case AvailabilityState.unknown:
        return 'Bluetooth status unavailable. Check Bluetooth settings and retry.';
      case AvailabilityState.poweredOn:
        return 'Bluetooth is on';
    }
  }

  bool _shouldPromptBleUnavailable(AvailabilityState state) {
    if (state == AvailabilityState.poweredOn) return false;
    if (state == AvailabilityState.unsupported) return false;
    if (kIsWeb) return false;
    final now = DateTime.now();
    final last = _lastBleUnavailablePromptAt;
    if (last != null && now.difference(last) < const Duration(seconds: 4)) {
      return false;
    }
    _lastBleUnavailablePromptAt = now;
    return true;
  }

  bool _isPlaceholderBleDeviceName(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isEmpty ||
        normalized == '(unnamed)' ||
        normalized == _knownBleDeviceFallbackName.toLowerCase() ||
        normalized == 'device';
  }

  String? _extractDeviceIdFromBleLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return null;
    final open = trimmed.lastIndexOf('[');
    final close = trimmed.lastIndexOf(']');
    if (open < 0 || close != trimmed.length - 1 || open + 1 >= close) {
      return null;
    }
    final id = trimmed.substring(open + 1, close).trim();
    return id.isEmpty ? null : id;
  }

  String _extractDeviceNameFromBleLabel(String label) {
    final trimmed = label.trim();
    final open = trimmed.lastIndexOf('[');
    if (open <= 0) return trimmed;
    return trimmed.substring(0, open).trim();
  }

  int _bleScanIndexByDeviceId(String deviceId) {
    if (deviceId.isEmpty) return -1;
    for (var i = 0; i < bleScanDevices.length; i++) {
      final entryId = _extractDeviceIdFromBleLabel(bleScanDevices[i]);
      if (entryId == deviceId) return i;
    }
    return -1;
  }

  String _bleDeviceLabel({required String deviceId, String? fallbackName}) {
    final mappedName = cleanRadioDisplayName(
      _bleDeviceNamesById[deviceId] ?? '',
    );
    final fallback = cleanRadioDisplayName(fallbackName ?? '');
    if (mappedName.isNotEmpty) return '$mappedName [$deviceId]';
    if (fallback.isNotEmpty) return '$fallback [$deviceId]';
    // Avoid generic "Known Device" labels; keep rows uniquely identifiable
    // until the platform provides a friendly BLE name.
    return '[$deviceId]';
  }

  bool _upsertBleScanDevice({required String deviceId, String? deviceName}) {
    final id = deviceId.trim();
    if (id.isEmpty) return false;
    final cleanedName = cleanRadioDisplayName(deviceName ?? '');
    if (cleanedName.isNotEmpty && !_isPlaceholderBleDeviceName(cleanedName)) {
      _bleDeviceNamesById[id] = cleanedName;
      if (settings.knownBleDeviceIds.contains(id) ||
          bleSelectedDeviceId == id) {
        unawaited(
          _persistKnownBleDeviceName(deviceId: id, deviceName: cleanedName),
        );
      }
    }
    final label = _bleDeviceLabel(deviceId: id, fallbackName: cleanedName);
    final index = _bleScanIndexByDeviceId(id);
    if (index < 0) {
      bleScanDevices = [...bleScanDevices, label];
      return true;
    }
    if (bleScanDevices[index] == label) return false;
    final updated = [...bleScanDevices];
    updated[index] = label;
    bleScanDevices = updated;
    return true;
  }

  void _seedKnownBleScanDevices() {
    var added = 0;
    for (final knownId in settings.knownBleDeviceIds) {
      if (_upsertBleScanDevice(deviceId: knownId)) {
        added += 1;
      }
    }
    if (added > 0) {
      _debugLog.info('ble_scan', 'Seeded $added known BLE device(s)');
    }
    unawaited(_resolveSeededBleDeviceNames());
  }

  Future<void> _resolveSeededBleDeviceNames() async {
    if (_transport is! BleTransport || kIsWeb) return;
    final ble = _transport;
    var updated = 0;
    for (final deviceId in settings.knownBleDeviceIds) {
      final existing = cleanRadioDisplayName(
        _bleDeviceNamesById[deviceId] ?? '',
      );
      if (existing.isNotEmpty && !_isPlaceholderBleDeviceName(existing)) {
        continue;
      }
      try {
        final resolved = cleanRadioDisplayName(
          await ble.resolveDeviceDisplayName(deviceId) ?? '',
        );
        if (resolved.isEmpty || _isPlaceholderBleDeviceName(resolved)) {
          continue;
        }
        if (!_upsertBleScanDevice(deviceId: deviceId, deviceName: resolved)) {
          continue;
        }
        updated += 1;
      } catch (_) {
        continue;
      }
    }
    if (updated > 0) {
      _debugLog.info(
        'ble_scan',
        'Resolved $updated known BLE device name(s) from system metadata',
      );
      notifyListeners();
    }
  }

  void _restoreKnownBleDeviceNames() {
    if (settings.knownBleDeviceNames.isEmpty) return;
    for (final entry in settings.knownBleDeviceNames.entries) {
      final id = entry.key.trim();
      final name = cleanRadioDisplayName(entry.value);
      if (id.isEmpty || _isPlaceholderBleDeviceName(name)) continue;
      _bleDeviceNamesById[id] = name;
    }
  }

  Future<void> _persistKnownBleDeviceName({
    required String deviceId,
    required String deviceName,
  }) async {
    final id = deviceId.trim();
    final name = cleanRadioDisplayName(deviceName);
    if (id.isEmpty || _isPlaceholderBleDeviceName(name)) return;
    final current = settings.knownBleDeviceNames[id];
    if (current == name) return;
    final nextNames = Map<String, String>.from(settings.knownBleDeviceNames);
    nextNames[id] = name;
    settings = settings.copyWith(knownBleDeviceNames: nextNames);
    await _settingsStore.save(settings);
  }

  void _primePreferredBleDeviceForScan() {
    if (_transport is! BleTransport) return;
    final selected = (bleSelectedDeviceId ?? '').trim();
    if (selected.isNotEmpty) {
      (_transport).preferredDeviceId = selected;
      return;
    }
    if (settings.knownBleDeviceIds.isNotEmpty) {
      (_transport).preferredDeviceId = settings.knownBleDeviceIds.first;
    }
  }

  Future<void> _handleBleUnavailableState({
    required AvailabilityState state,
    required String context,
    bool prompt = true,
  }) async {
    if (state == AvailabilityState.unsupported) {
      _setBleUnavailableStatus(context: context);
      return;
    }
    bleConnected = false;
    bleConnecting = false;
    bleBusy = false;
    bleScanning = false;
    bleDeviceScanInProgress = false;
    bleScanStatus = 'idle';
    _bleAutoScanTimer?.cancel();
    _bleCountdownTimer?.cancel();
    _stopPassiveAdvertListener();
    _resetAutoScanSchedule();
    _smartScanPausedForRecentCoverage = false;
    _smartScanPausedZoneId = null;
    bleStatus = _bleUnavailableStateMessage(state);
    _debugLog.warn(context, '$bleStatus state=$state');
    _signalContactSyncLinkClosed();
    _syncAndroidScanForeground();
    notifyListeners();

    if (_scanLoopWanted &&
        !bleConnected &&
        !_manualBleDisconnectRequested &&
        !kIsWeb &&
        state != AvailabilityState.unsupported) {
      _armScanLoopReconnect(reason: 'bluetooth ${state.name}');
    }

    if (prompt &&
        _shouldPromptBleUnavailable(state) &&
        onBleUnavailablePrompt != null) {
      await onBleUnavailablePrompt!(state: state, context: context);
    }
  }

  Future<bool> _ensureBleAvailable({
    String context = 'ble',
    bool prompt = true,
  }) async {
    if (debugBleReady) return true;
    if (_transport is! BleTransport) return false;
    try {
      final state = await _transport.getAvailabilityState();
      if (state != AvailabilityState.poweredOn) {
        await _handleBleUnavailableState(
          state: state,
          context: context,
          prompt: prompt,
        );
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

  String _resolveDiscoverName({
    required String nodeId,
    required String incomingName,
  }) {
    // Keep the advertised name on the discover model. Repeater/room contact
    // names are applied when scans are stored or backfilled, not here, so
    // companion contact names cannot leak onto the discover payload.
    final trimmed = incomingName.trim();
    if (!isPlaceholderNodeName(trimmed, nodeId)) {
      return trimmed;
    }
    return '';
  }

  String _discoverResponderLabel({
    required String nodeId,
    required String name,
  }) {
    final resolved = cleanRadioDisplayName(name);
    if (resolved.isNotEmpty && !isPlaceholderNodeName(resolved, nodeId)) {
      return resolved;
    }
    final normalizedNodeId = normalizeHexId(nodeId);
    if (normalizedNodeId.isEmpty) return 'Unknown';
    return normalizedNodeId.length <= 8
        ? normalizedNodeId
        : normalizedNodeId.substring(0, 8);
  }

  String _discoverStatusLine({
    required String nodeId,
    required String name,
    num? rssi,
    num? snr,
  }) {
    final label = _discoverResponderLabel(nodeId: nodeId, name: name);
    if (rssi == null && snr == null) return '$label · Discovered';
    final parts = <String>[label];
    if (rssi != null) {
      parts.add('RSSI ${rssi.toStringAsFixed(0)}');
    }
    if (snr != null) {
      parts.add('SNR ${snr.toStringAsFixed(1)}');
    }
    return parts.join(' · ');
  }

  String _frameCodeName(int code) {
    switch (code) {
      case respCodeOk:
        return 'respCodeOk';
      case respCodeErr:
        return 'respCodeErr';
      case respCodeContactsStart:
        return 'respCodeContactsStart';
      case respCodeContact:
        return 'respCodeContact';
      case respCodeEndOfContacts:
        return 'respCodeEndOfContacts';
      case respCodeSelfInfo:
        return 'respCodeSelfInfo';
      case respCodeSent:
        return 'respCodeSent';
      case respCodeContactMsgRecv:
        return 'respCodeContactMsgRecv';
      case respCodeChannelMsgRecv:
        return 'respCodeChannelMsgRecv';
      case respCodeCurrTime:
        return 'respCodeCurrTime';
      case respCodeNoMoreMessages:
        return 'respCodeNoMoreMessages';
      case respCodeExportContact:
        return 'respCodeExportContact';
      case respCodeBattAndStorage:
        return 'respCodeBattAndStorage';
      case respCodeDeviceInfo:
        return 'respCodeDeviceInfo';
      case respCodeContactMsgRecvV3:
        return 'respCodeContactMsgRecvV3';
      case respCodeChannelMsgRecvV3:
        return 'respCodeChannelMsgRecvV3';
      case respCodeChannelInfo:
        return 'respCodeChannelInfo';
      case respCodeSignStart:
        return 'respCodeSignStart';
      case respCodeSignature:
        return 'respCodeSignature';
      case respCodeCustomVars:
        return 'respCodeCustomVars';
      case respCodeAutoAddConfig:
        return 'respCodeAutoAddConfig';
      case pushCodeAdvert:
        return 'pushCodeAdvert';
      case pushCodePathUpdated:
        return 'pushCodePathUpdated';
      case pushCodeSendConfirmed:
        return 'pushCodeSendConfirmed';
      case pushCodeMsgWaiting:
        return 'pushCodeMsgWaiting';
      case pushCodeLoginSuccess:
        return 'pushCodeLoginSuccess';
      case pushCodeLoginFail:
        return 'pushCodeLoginFail';
      case pushCodeStatusResponse:
        return 'pushCodeStatusResponse';
      case pushCodeLogRxData:
        return 'pushCodeLogRxData';
      case pushCodeTraceData:
        return 'pushCodeTraceData';
      case pushCodeNewAdvert:
        return 'pushCodeNewAdvert';
      case pushCodeTelemetryResponse:
        return 'pushCodeTelemetryResponse';
      case pushCodeBinaryResponse:
        return 'pushCodeBinaryResponse';
      case pushCodeControlData:
        return 'pushCodeControlData';
      case pushCodeAdvertCompact:
        return 'pushCodeAdvertCompact';
      default:
        return code < 0 ? 'empty_frame' : 'unknown';
    }
  }

  bool _cacheAdvertName({
    required String nodeId,
    required String name,
    required String source,
  }) {
    final safeId = safePublicRadioId(nodeId);
    if (safeId == null || safeId.isEmpty) return false;
    final trimmed = name.trim();
    if (isPlaceholderNodeName(trimmed, safeId)) return false;
    final existing = _bestContactNameForId(_radioContactsByPrefix, safeId);
    if ((existing ?? '').trim() == trimmed) return false;
    _radioContactsByPrefix[safeId] = trimmed;
    _debugLog.debug(
      'ble_advert',
      'Cached advert name id=$safeId name=$trimmed source=$source',
    );
    return true;
  }

  void _startPassiveAdvertListener() {
    if (_passiveAdvertSubscription != null) return;
    _passiveAdvertSubscription = _transport.inbound.listen((frame) {
      final advert = parseNodeDiscoverAdvertResponse(frame);
      if (advert == null) return;
      _cacheAdvertName(
        nodeId: advert.publicKeyPrefix,
        name: advert.name,
        source: 'passive',
      );
      if (bleDiscoveries.isEmpty) return;
      final resolvedName = _resolveDiscoverName(
        nodeId: advert.publicKeyPrefix,
        incomingName: advert.name,
      );
      if (resolvedName.isEmpty) return;

      var changed = false;
      final nextDiscoveries = bleDiscoveries
          .map((response) {
            if (!idsLikelySameDevice(
              response.publicKeyPrefix,
              advert.publicKeyPrefix,
            )) {
              return response;
            }
            if (!isPlaceholderNodeName(
              response.name,
              response.publicKeyPrefix,
            )) {
              return response;
            }
            if (response.name.trim() == resolvedName) {
              return response;
            }
            changed = true;
            return NodeDiscoverResponse(
              snr: response.snr,
              rssi: response.rssi,
              snrIn: response.snrIn,
              nodeType: response.nodeType,
              tagHex: response.tagHex,
              publicKeyPrefix: response.publicKeyPrefix,
              name: resolvedName,
            );
          })
          .toList(growable: false);
      if (!changed) return;
      bleDiscoveries = nextDiscoveries;
      _debugLog.debug(
        'ble_advert',
        'Applied passive advert names to active discoveries',
      );
      notifyListeners();
    });
    _debugLog.debug('ble_advert', 'Passive advert listener started');
  }

  void _stopPassiveAdvertListener() {
    final sub = _passiveAdvertSubscription;
    if (sub == null) return;
    _passiveAdvertSubscription = null;
    unawaited(sub.cancel());
    _debugLog.debug('ble_advert', 'Passive advert listener stopped');
  }

  bool _autoReconnectInProgress = false;
  bool _resumeAutoScanAfterReconnect = false;

  /// User started the scan loop and has not paused, disconnected, or
  /// abandoned reconnect. A failed reconnect must not clear this.
  bool _scanLoopWanted = false;
  int _scanReconnectAttempt = 0;
  int _scanReconnectGeneration = 0;
  Timer? _scanReconnectTimer;
  bool _scanReconnectAttemptActive = false;
  int _silentBleConnectDepth = 0;
  bool? _batteryOptimizationPromptAsked;
  bool _batteryOptPromptInFlight = false;
  Future<bool> Function()? onBatteryOptimizationPrompt;
  bool _smartScanReevaluatePending = false;
  bool _smartScanPausedForRecentCoverage = false;
  String? _smartScanPausedZoneId;
  DateTime? _lastSmartScanPauseLogAt;
  DateTime? _lastSmartScanSkipAt;
  int _autoScanRemainingSeconds = 0;
  bool _autoScanDueWhileBusy = false;
  bool _autoScanTickInProgress = false;
  int _autoScanCycleSeq = 0;
  DateTime? _lastAutoScanTriggerAt;
  DateTime? _nextAutoScanDueAt;
  String? _connectedRadioMeshIdPrefix;
  String? _connectedRadioPublicKeyHex;
  String? _connectedRadioDisplayName;
  String? _lastSelfInfoHex;
  String? _lastSelfInfoText;
  bool _deleteInProgress = false;
  bool _hostDetaching = false;
  Future<String?> Function(String deviceId)? onBlePinRequest;
  set onLocationPermissionPrompt(
    Future<bool> Function({required bool background})? fn,
  ) => _locationService.onLocationPermissionPrompt = fn;
  Future<void> Function({
    required AvailabilityState state,
    required String context,
  })?
  onBleUnavailablePrompt;
  DateTime? _lastBleUnavailablePromptAt;

  List<RawScan> rawScans = const [];
  List<CoverageZone> coverageZones = const [];
  List<CoverageOverviewCell> coverageOverviewCells = const [];
  final CoverageOverviewCache _overviewCache;
  final WorkerApi Function()? _coverageOverviewApi;
  bool _overviewFetchRunning = false;
  List<MeshNode> nodes = const [];
  List<ScanResult> scanResults = const [];
  List<MeshNode>? _advertisedNodes;
  List<ScanResult>? _advertisedResults;
  List<RawScan>? _advertisedRaw;
  FirstAdvertisedNameIndex? _advertisedNames;
  LongestHexNameIndex? _sessionNameIndex;
  int _sessionNameCount = -1;
  List<AppDebugLogEntry> get debugLogs => _debugLog.entries;
  String? get connectedRadioName {
    if (!bleConnected) return null;
    final name =
        connectedRadioDisplayName ??
        cleanRadioDisplayName(_selectedBleDeviceName());
    if (name.isEmpty) return null;
    return name;
  }

  String? get connectedRadioDisplayName => _connectedRadioDisplayName;
  String? get connectedRadioMeshId8 => _connectedRadioMeshId8();
  String? get connectedRadioPublicKeyHex => _connectedRadioPublicKeyHex;

  Map<String, int> get currentRadioContactTypes =>
      Map<String, int>.unmodifiable(_sessionRadioContactTypes);

  Map<String, String> get currentRadioContacts {
    if (bleConnected) {
      return Map<String, String>.unmodifiable(_sessionRadioContacts);
    }
    final radioId = _connectedRadioMeshId8();
    if (radioId == null || radioId.isEmpty) return const {};
    return Map<String, String>.unmodifiable(
      settings.contactsByRadioId[radioId] ?? const <String, String>{},
    );
  }

  /// Repeater/node label.
  ///
  /// Order: in-memory session contact, advertised/discovered name already on
  /// the node or scan, then the short public-key prefix. Session contact names
  /// are shown locally for every type. Only repeater/room contact names are
  /// written onto scans for upload.
  String displayNameForNode(String nodeId, {String? advertisedName}) {
    final fromSession = _bestContactNameForId(_sessionRadioContacts, nodeId);
    final hinted = (advertisedName ?? '').trim();
    final hintedUsable =
        hinted.isNotEmpty && !isPlaceholderNodeName(hinted, nodeId)
        ? hinted
        : null;
    return titleNameForNode(
      nodeId: nodeId,
      contactName: fromSession,
      advertisedName: hintedUsable ?? _storedAdvertisedName(nodeId),
    );
  }

  /// Debug line for title diagnosis. Never includes a contact or advert name.
  String _contactsMatchLog({
    required String nodeId,
    required bool matched,
    required bool hasAdvertName,
  }) {
    final node = shortNodeId(nodeId);
    return 'contacts_match node=$node matched=${matched ? 'yes' : 'no'} '
        'has_advert_name=${hasAdvertName ? 'yes' : 'no'}';
  }

  void _logKnownNodeContactMatches() {
    final seen = <String>{};
    final ids = <String>[];
    void add(String? raw) {
      final trimmed = (raw ?? '').trim();
      if (trimmed.isEmpty) return;
      final node = shortNodeId(trimmed);
      if (node.isEmpty || node == 'Unknown') return;
      if (!seen.add(node)) return;
      ids.add(trimmed);
    }

    for (final node in nodes) {
      add(node.nodeId);
    }
    if (ids.isEmpty) {
      for (final scan in rawScans) {
        add(scan.nodeId);
      }
    }
    for (final id in ids) {
      _debugLog.debug(
        'contacts',
        _contactsMatchLog(
          nodeId: id,
          matched: _bestContactNameForId(_sessionRadioContacts, id) != null,
          hasAdvertName: _storedAdvertisedName(id) != null,
        ),
      );
    }
  }

  @visibleForTesting
  void debugLogKnownNodeContactMatches() {
    _logKnownNodeContactMatches();
  }

  @visibleForTesting
  void debugSeedSessionContacts(
    Map<String, String> contacts, {
    Map<String, int>? types,
  }) {
    _sessionRadioContacts
      ..clear()
      ..addAll(contacts);
    _sessionRadioContactTypes.clear();
    if (types != null) {
      _sessionRadioContactTypes.addAll(types);
    }
    _invalidateSessionContactLookup();
  }

  @visibleForTesting
  int debugBackfillScanNamesFromContacts(Map<String, String> contacts) {
    return _backfillScanNamesFromContacts(contacts);
  }

  @visibleForTesting
  Map<String, dynamic>? debugToWorkerScanPayload(RawScan scan) {
    return _toWorkerScanPayload(scan);
  }

  @visibleForTesting
  String debugResolveScanSenderName({
    required String nodeId,
    required String advertisedName,
  }) {
    return _resolveScanSenderName(
      nodeId: nodeId,
      advertisedName: advertisedName,
    );
  }

  bool get deleteInProgress => _deleteInProgress;
  Map<String, String> get knownContactNames =>
      Map<String, String>.unmodifiable(_radioContactsByPrefix);
  int get localScanCount => rawScans.length;
  int get uploadQueueCount =>
      rawScans.where((scan) => scan.uploadEligible).length;
  List<RawScan> get uploadCandidates =>
      rawScans.where((scan) => scan.uploadEligible).toList(growable: false);
  int get periodicSyncIntervalMinutes => _resolvedPeriodicSyncIntervalMinutes();
  bool get periodicSyncEnabled => !settings.forceOffline;
  bool get periodicSyncWaitingForInternetTimeAnchor =>
      periodicSyncEnabled && _syncService.waitingForInternetTimeAnchor;
  DateTime? get nextPeriodicSyncDueAtUtc => periodicSyncEnabled
      ? _syncService.nextPeriodicSyncDueAtUtc(periodicSyncIntervalMinutes)
      : null;

  (double, double)? get currentObserverPosition {
    // Never a scan, a zone, or a server payload. Those belong to whoever
    // recorded them. The web map ignores a stored fix so a visitor who has
    // not granted location stays on the general view.
    return ownDeviceMapFix(
      deviceLatitude: deviceLatitude,
      deviceLongitude: deviceLongitude,
      storedLatitude: _cachedFixLat,
      storedLongitude: _cachedFixLng,
      allowStoredFix: !kIsWeb,
    );
  }

  Future<void> initialize() async {
    _debugLog.info('app_state', 'Initializing app state');
    loading = true;
    notifyListeners();

    settings = await _settingsStore.load();
    var settingsDirty = false;
    if (!settings.privacyAccepted && !settings.forceOffline) {
      settings = settings.copyWith(forceOffline: true);
      settingsDirty = true;
    }
    // One-time: initial Accept used to leave forceOffline set. Clear that
    // once, then set the flag for every install so a later deliberate
    // offline choice is not cleared on the next launch.
    if (!settings.privacyForceOfflineMigrated) {
      final clearStuckOffline =
          settings.privacyAccepted && settings.forceOffline;
      settings = settings.copyWith(
        forceOffline: clearStuckOffline ? false : settings.forceOffline,
        privacyForceOfflineMigrated: true,
      );
      settingsDirty = true;
      if (clearStuckOffline) {
        _debugLog.info(
          'privacy',
          'Cleared stuck offline mode after privacy acceptance',
        );
      }
    }
    if (settingsDirty) {
      await _settingsStore.save(settings);
    }
    final startup = await _allDaysGuard.resolveInterruptedStartup(
      settings: settings,
      saveSettings: _settingsStore.save,
    );
    settings = startup.settings;
    if (startup.fellBackToLast7) {
      _debugLog.info(
        'app_state',
        'Interrupted all-days history fell back to last 7 days',
      );
    }
    // TODO: Re-enable user-selectable language setting.
    // Language setting is temporarily disabled; keep app language fixed to English.
    AppI18n.instance.setLanguage('en');
    final storedFix = await _lastKnownFixStore.load();
    if (storedFix != null) {
      _cachedFixLat = storedFix.latitude;
      _cachedFixLng = storedFix.longitude;
    }
    _restoreKnownBleDeviceNames();
    _radioContactsByPrefix.clear();
    for (final contacts in settings.contactsByRadioId.values) {
      _radioContactsByPrefix.addAll(contacts);
    }

    // Settings must be reachable before the legacy cache parse. An interrupted
    // all-days load is already fallen back; a first upgrade still parses the
    // full cache, but off the UI isolate and only after the guard is armed.
    loading = false;
    notifyListeners();
    final overviewCacheFresh = await _showCachedCoverageOverview();
    if (!overviewCacheFresh && !settings.forceOffline) {
      unawaited(_fetchCoverageOverviewFromNetwork());
    }
    await Future<void>.delayed(Duration.zero);

    var runtimeStarted = false;
    void startRuntime() {
      if (runtimeStarted) return;
      runtimeStarted = true;
      _seedKnownBleScanDevices();
      _primePreferredBleDeviceForScan();
      notifyListeners();
      if (settings.bleAutoConnect && settings.knownBleDeviceIds.isNotEmpty) {
        bleSelectedDeviceId = settings.knownBleDeviceIds.first;
        if (_transport is BleTransport) {
          (_transport).preferredDeviceId = bleSelectedDeviceId;
        }
        unawaited(connectBle());
      }
      unawaited(_locationService.startTracking());
    }

    try {
      await _allDaysGuard.guardedAllDaysLoad(
        settings: settings,
        load: () async {
          await _loadCachedHistory();
          startRuntime();
          if (settings.forceOffline) {
            await _pruneCacheAndPersist();
            return;
          }
          await syncFromWorker();
          if (requestsAllDays(
                historyDays: settings.historyDays,
                deadzoneDays: settings.deadzoneDays,
              ) &&
              !_lastWorkerSyncSucceeded) {
            _debugLog.warn(
              'app_state',
              'All-days history load did not finish; '
                  'next startup falls back to last 7',
            );
            throw const AllDaysLoadIncomplete();
          }
        },
      );
    } catch (e) {
      _debugLog.error('app_state', 'History startup failed: $e');
      startRuntime();
    } finally {
      _startupSyncFinished = true;
    }
    _configurePeriodicSyncTimer();
  }

  Future<bool> _showCachedCoverageOverview() async {
    try {
      final cached = await _overviewCache.load();
      if (cached == null) return false;
      coverageOverviewCells = cached.overview.cells;
      notifyListeners();
      return cached.fresh;
    } catch (error) {
      _debugLog.warn('coverage_overview', 'Cached overview unreadable: $error');
      return false;
    }
  }

  Future<void> _fetchCoverageOverviewFromNetwork() async {
    if (settings.forceOffline || _overviewFetchRunning) return;
    _overviewFetchRunning = true;
    try {
      final api =
          _coverageOverviewApi?.call() ??
          WorkerApi(
            AppConfig.deployedWorkerUrl,
            fallbackBaseUrl: AppConfig.fallbackWorkerUrl,
            staticDataBaseUrl: AppConfig.staticDataUrl,
          );
      final fresh = await api.fetchCoverageOverview();
      if (fresh == null) return;
      coverageOverviewCells = fresh.cells;
      notifyListeners();
      try {
        await _overviewCache.save(fresh);
      } catch (error) {
        _debugLog.warn(
          'coverage_overview',
          'Overview cache write failed: $error',
        );
      }
      _debugLog.info(
        'coverage_overview',
        'General coverage cells=${fresh.cells.length}',
      );
    } catch (error) {
      _debugLog.warn('coverage_overview', 'Overview fetch skipped: $error');
    } finally {
      _overviewFetchRunning = false;
    }
  }

  /// Shows a stored overview, then fetches when that copy is older than an hour.
  Future<void> refreshCoverageOverview() async {
    final fresh = await _showCachedCoverageOverview();
    if (fresh || settings.forceOffline) return;
    await _fetchCoverageOverviewFromNetwork();
  }

  Future<void> _loadCachedHistory() async {
    final path = currentMeshDatabasePath();
    if (!kIsWeb && path != null) {
      await _loadCachedHistoryFromDatabase(path);
      return;
    }
    await _loadCachedHistoryInline();
  }

  Future<void> _loadCachedHistoryFromDatabase(String path) async {
    historyLoadLabel = 'Loading saved history (0)';
    notifyListeners();
    try {
      await ReaxDatabase.beginExclusiveDatabaseAccess();
      try {
        final loaded = await loadPersistedHistory(
          path,
          onLoaded: (count) {
            historyLoadLabel = 'Loading saved history ($count)';
            notifyListeners();
          },
        );
        rawScans = loaded.scans;
        _applyLocalStamp();
        coverageZones = loaded.zones;
        nodes = loaded.nodes;
        scanResults = loaded.scanResults;
        _logSuppressedDeadzoneRows(loaded.suppressedRows, 'local_cache');
        if (loaded.persistedChanges) {
          _debugLog.info(
            'app_state',
            'Rewrote cached history after normalization',
          );
        }
      } finally {
        await ReaxDatabase.endExclusiveDatabaseAccess();
      }
    } finally {
      historyLoadLabel = null;
      notifyListeners();
    }
  }

  Future<void> _loadCachedHistoryInline() async {
    historyLoadLabel = 'Loading saved history';
    notifyListeners();
    try {
      final stored = await _localStore.loadRawScans();
      final prepared = await runOffUi(prepareRawScansWorker, <String, Object?>{
        'scans': stored,
      }, weight: stored.length);
      rawScans = prepared.scans;
      _applyLocalStamp();
      _logSuppressedDeadzoneRows(prepared.suppressedRows, 'local_cache');
      if (prepared.changed) {
        await _localStore.saveRawScans(rawScans);
      }
      await _rebuildDerivedData();
    } finally {
      historyLoadLabel = null;
      notifyListeners();
    }
  }

  void _logSuppressedDeadzoneRows(int suppressedRows, String source) {
    if (suppressedRows <= 0) return;
    _debugLog.info(
      'sync',
      'Suppressed $suppressedRows deadzone row(s) in hexes with '
          'successful scans ($source)',
    );
  }

  Future<void> _maybePersistRadioSettings(AppSettings next) async {
    if (!localContactsSupported) return;
    final radioId = _connectedRadioMeshId8();
    if (radioId == null || radioId.isEmpty || !bleConnected) return;
    await _contactStore.saveRadioSettings(radioId, next);
  }

  Future<void> _maybeLoadRadioSettings() async {
    if (!localContactsSupported) return;
    final radioId = _connectedRadioMeshId8();
    if (radioId == null || radioId.isEmpty) return;
    final loaded = await _contactStore.loadRadioSettings(radioId);
    if (loaded == null) {
      await _contactStore.saveRadioSettings(radioId, settings);
      return;
    }
    settings = !loaded.privacyAccepted && !loaded.forceOffline
        ? loaded.copyWith(forceOffline: true)
        : loaded;
    await _settingsStore.save(settings);
  }

  Future<void> updateSettings(AppSettings next) async {
    final previous = settings;
    settings = !next.privacyAccepted && !next.forceOffline
        ? next.copyWith(forceOffline: true)
        : next;
    // Startup forces offline until privacy is accepted, so the first overview
    // fetch never runs. Accepting privacy and turning Online Mode on are both
    // this transition. Start the fetch before the awaits below; a later save
    // or guard write must not drop it.
    final wentOnline = previous.forceOffline && !settings.forceOffline;
    final acceptedPrivacy =
        !previous.privacyAccepted && settings.privacyAccepted;
    if ((wentOnline || acceptedPrivacy) && !settings.forceOffline) {
      unawaited(refreshCoverageOverview());
    }
    // TODO: Re-enable user-selectable language setting.
    // Language setting is temporarily disabled; keep app language fixed to English.
    AppI18n.instance.setLanguage('en');
    final windowChanged =
        previous.historyDays != settings.historyDays ||
        previous.deadzoneDays != settings.deadzoneDays ||
        previous.forceOffline != settings.forceOffline;
    if (windowChanged) {
      _historyLoadToken++;
    }
    await _settingsStore.save(settings);
    if (windowChanged &&
        !requestsAllDays(
          historyDays: settings.historyDays,
          deadzoneDays: settings.deadzoneDays,
        )) {
      await _allDaysGuard.clear();
    }
    await _maybePersistRadioSettings(settings);
    notifyListeners();
    if (!sameScanCacheArea(
      previousMode: previous.scanCacheMode,
      nextMode: settings.scanCacheMode,
      previousRadiusMiles: previous.scanCacheRadiusMiles,
      nextRadiusMiles: settings.scanCacheRadiusMiles,
      previousAdmin1Ids: previous.scanCacheAdmin1Ids,
      nextAdmin1Ids: settings.scanCacheAdmin1Ids,
      previousAdmin2Ids: previous.scanCacheAdmin2Ids,
      nextAdmin2Ids: settings.scanCacheAdmin2Ids,
    )) {
      final expands = scanCacheAreaExpands(
        previousMode: previous.scanCacheMode,
        nextMode: settings.scanCacheMode,
        previousRadiusMiles: previous.scanCacheRadiusMiles,
        nextRadiusMiles: settings.scanCacheRadiusMiles,
        previousAdmin1Ids: previous.scanCacheAdmin1Ids,
        nextAdmin1Ids: settings.scanCacheAdmin1Ids,
        previousAdmin2Ids: previous.scanCacheAdmin2Ids,
        nextAdmin2Ids: settings.scanCacheAdmin2Ids,
      );
      if (syncing || _workerSyncStarting) {
        if (expands && !settings.forceOffline) {
          _expandDuringSync = true;
        } else {
          _pruneAfterSync = true;
        }
      } else if (expands && !settings.forceOffline) {
        unawaited(syncFromWorker());
      } else {
        unawaited(_pruneCacheAndPersist());
      }
    }

    final travelChanged =
        previous.travelDownloadEnabled != settings.travelDownloadEnabled ||
        previous.travelRadiusMiles != settings.travelRadiusMiles;
    if (travelChanged) {
      if (settings.travelDownloadEnabled && !settings.forceOffline) {
        final lat = _scanCacheCenterLat();
        final lng = _scanCacheCenterLng();
        if (lat != null && lng != null) {
          unawaited(
            _considerTravelFetch(
              lat,
              lng,
              ignoreInterval: !previous.travelDownloadEnabled,
            ),
          );
        }
      } else {
        unawaited(_pruneCacheAndPersist());
      }
    }

    // The pending due follows the slider immediately: last anchor + the new
    // interval. Do not start a discover for the change itself. A due that is
    // already past is picked up by the next 1s tick.
    if (previous.scanIntervalSeconds != settings.scanIntervalSeconds &&
        bleScanning &&
        _nextAutoScanDueAt != null) {
      final anchor = _lastAutoScanTriggerAt ?? DateTime.now();
      _scheduleNextAutoScanFrom(anchor);
      final remaining = _secondsUntilNextAutoScan(DateTime.now());
      _autoScanRemainingSeconds = remaining;
      bleNextScanCountdown = remaining;
      notifyListeners();
    }

    final smartChanged =
        previous.smartScanEnabled != settings.smartScanEnabled ||
        previous.smartScanDays != settings.smartScanDays;
    if (smartChanged && bleScanning && bleConnected) {
      if (bleBusy) {
        if (!_smartScanReevaluatePending) {
          _smartScanReevaluatePending = true;
          _debugLog.info(
            'smart_scan',
            'Settings changed during active scan; queued smart-scan re-evaluation',
          );
        }
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

    // --- Auto-connect toggle changed ---
    final autoConnectChanged =
        previous.bleAutoConnect != settings.bleAutoConnect;
    if (autoConnectChanged) {
      if (settings.bleAutoConnect) {
        // Toggled ON: connect if we have a known device and are not already
        // connected or connecting.
        if (!bleConnected &&
            !bleConnecting &&
            settings.knownBleDeviceIds.isNotEmpty) {
          bleSelectedDeviceId ??= settings.knownBleDeviceIds.first;
          if (_transport is BleTransport) {
            _transport.preferredDeviceId = bleSelectedDeviceId;
          }
          _debugLog.info(
            'ble',
            'Auto-connect enabled; connecting to $bleSelectedDeviceId',
          );
          unawaited(connectBle());
        }
      } else {
        // Toggled OFF: disconnect gracefully so the radio is released.
        if (bleConnected || bleConnecting) {
          _debugLog.info('ble', 'Auto-connect disabled; disconnecting');
          unawaited(disconnectBle());
        }
      }
    }
  }

  Future<void> setAutoCenter(bool value) async {
    await updateSettings(settings.copyWith(autoCenter: value));
  }

  void _applyLocalStamp() {
    final stamped = stampLocallyRecorded(rawScans);
    if (identical(stamped, rawScans)) return;
    rawScans = stamped;
    _localStampDirty = true;
  }

  double? _scanCacheCenterLat() => deviceLatitude ?? _cachedFixLat;

  double? _scanCacheCenterLng() => deviceLongitude ?? _cachedFixLng;

  Future<List<RawScan>> _prunedForCacheArea(List<RawScan> scans) {
    return _scanCache.prune(
      scans: scans,
      settings: settings,
      centerLat: _scanCacheCenterLat(),
      centerLng: _scanCacheCenterLng(),
    );
  }

  TravelAreaAnchor? _newestTravelAnchor() {
    final active = activeTravelAnchors(
      settings.travelAnchors,
      DateTime.now().toUtc(),
    );
    if (active.isEmpty) return null;
    return active.first;
  }

  /// Radius uses the previous disk, because the live center is the device
  /// itself. Admin modes test the selected outlines. Global is never outside.
  Future<bool> _deviceIsOutsideCache({
    required double lat,
    required double lng,
    double? radiusCenterLat,
    double? radiusCenterLng,
  }) async {
    final mode = clampScanCacheMode(settings.scanCacheMode);
    if (mode == scanCacheModeGlobal) return false;
    if (mode == scanCacheModeRadius) {
      return deviceOutsideRadiusCache(
        deviceLat: lat,
        deviceLng: lng,
        centerLat: radiusCenterLat,
        centerLng: radiusCenterLng,
        radiusMiles: settings.scanCacheRadiusMiles,
      );
    }
    final counties = mode == scanCacheModeAdmin2;
    final ids = counties
        ? settings.scanCacheAdmin2Ids
        : settings.scanCacheAdmin1Ids;
    final key = '$mode|${hexKey(lat, lng)}|${ids.join(',')}';
    if (key == _outsideDivisionKey) return _outsideDivisionValue;
    final inside = await _scanCache.containsDivisionPoint(
      counties: counties,
      selectedIds: ids,
      latitude: lat,
      longitude: lng,
    );
    _outsideDivisionKey = key;
    _outsideDivisionValue = !inside;
    return _outsideDivisionValue;
  }

  Future<CloudFetchQuery> _homeCloudQuery() async {
    final mode = clampScanCacheMode(settings.scanCacheMode);
    final centerLat = _scanCacheCenterLat();
    final centerLng = _scanCacheCenterLng();
    DivisionBbox? bbox;
    if (mode == scanCacheModeAdmin1 || mode == scanCacheModeAdmin2) {
      final counties = mode == scanCacheModeAdmin2;
      final ids = counties
          ? settings.scanCacheAdmin2Ids
          : settings.scanCacheAdmin1Ids;
      bbox = await _scanCache.bboxFor(counties: counties, selectedIds: ids);
    }
    // [centerLat]/[centerLng] are the live fix, or the last known fix.
    // A states/counties query uses that point when it lies inside the box.
    return cloudQueryForCache(
      mode: mode,
      radiusMiles: settings.scanCacheRadiusMiles,
      centerLat: centerLat,
      centerLng: centerLng,
      divisionBbox: bbox,
    );
  }

  /// Extra bubble for a full sync. Radius mode already fetches around the
  /// device, so this is only for a division cache the device has left.
  Future<CloudFetchQuery?> _travelQueryDuringSync() async {
    if (!settings.travelDownloadEnabled) return null;
    final mode = clampScanCacheMode(settings.scanCacheMode);
    if (mode == scanCacheModeGlobal || mode == scanCacheModeRadius) {
      return null;
    }
    final lat = _scanCacheCenterLat();
    final lng = _scanCacheCenterLng();
    if (lat == null || lng == null) return null;
    final outside = await _deviceIsOutsideCache(
      lat: lat,
      lng: lng,
      radiusCenterLat: lat,
      radiusCenterLng: lng,
    );
    if (!outside) return null;
    return CloudFetchQuery(
      skip: false,
      latitude: lat,
      longitude: lng,
      radiusMiles: settings.travelRadiusMiles,
    );
  }

  void _logWorkerRadiusCap(CloudFetchQuery query) {
    final miles = query.radiusMiles;
    if (miles == null || miles <= workerScanRadiusCapMiles) return;
    final box = query.hasBounds
        ? ' A bounding box is sent for servers that accept one.'
        : '';
    _debugLog.info(
      'sync',
      'Requested $miles mi.$box Older servers still cap radius at '
          '$workerScanRadiusCapMiles mi. Local prune still uses the full cache area.',
    );
  }

  Future<void> _rememberTravelCenter(double lat, double lng) async {
    final next = rememberTravelFetch(
      anchors: settings.travelAnchors,
      latitude: lat,
      longitude: lng,
      radiusMiles: settings.travelRadiusMiles,
      now: DateTime.now().toUtc(),
    );
    settings = settings.copyWith(travelAnchors: next);
    await _settingsStore.save(settings);
  }

  Future<void> _pruneCacheAndPersist() async {
    if (_cachePruneRunning || syncing || _workerSyncStarting) return;
    _cachePruneRunning = true;
    try {
      final pruned = await _prunedForCacheArea(rawScans);
      if (identical(pruned, rawScans) && !_localStampDirty) return;
      rawScans = pruned;
      _localStampDirty = false;
      await _localStore.saveRawScans(rawScans);
      await _rebuildDerivedData();
      notifyListeners();
    } catch (error) {
      _debugLog.warn('cache', 'Scan cache prune failed: $error');
    } finally {
      _cachePruneRunning = false;
    }
  }

  Future<void> _rememberDeviceFix(double lat, double lng) async {
    final previousLat = _cachedFixLat;
    final previousLng = _cachedFixLng;
    final movedMiles = previousLat == null || previousLng == null
        ? null
        : distanceMiles(previousLat, previousLng, lat, lng);
    _cachedFixLat = lat;
    _cachedFixLng = lng;
    if (movedMiles == null || movedMiles >= 1) {
      try {
        await _lastKnownFixStore.save(lat, lng);
      } catch (error) {
        _debugLog.warn('cache', 'Could not store last location: $error');
      }
    }
    if (!_startupSyncFinished) return;
    if (previousLat == null &&
        !settings.forceOffline &&
        clampScanCacheMode(settings.scanCacheMode) == scanCacheModeRadius) {
      // Startup had no fix, so the radius fetch was skipped. Pull it now.
      unawaited(syncFromWorker());
      return;
    }
    if (settings.travelDownloadEnabled) {
      final started = await _considerTravelFetch(
        lat,
        lng,
        radiusCenterLat: previousLat,
        radiusCenterLng: previousLng,
      );
      if (started) return;
    }
    if (!scanCacheFixShouldReprune(
      mode: settings.scanCacheMode,
      radiusMiles: settings.scanCacheRadiusMiles,
      previousLat: previousLat,
      previousLng: previousLng,
      lat: lat,
      lng: lng,
    )) {
      return;
    }
    await _pruneCacheAndPersist();
  }

  /// Starts a travel download when the device is outside the cache area and
  /// the throttle allows it. Returns true when a download was started.
  Future<bool> _considerTravelFetch(
    double lat,
    double lng, {
    double? radiusCenterLat,
    double? radiusCenterLng,
    bool ignoreInterval = false,
  }) async {
    if (settings.forceOffline) return false;
    final outside = await _deviceIsOutsideCache(
      lat: lat,
      lng: lng,
      radiusCenterLat: radiusCenterLat,
      radiusCenterLng: radiusCenterLng,
    );
    final newest = ignoreInterval ? null : _newestTravelAnchor();
    final decision = decideTravelFetch(
      enabled: settings.travelDownloadEnabled,
      forceOffline: settings.forceOffline,
      networkAvailable: true,
      syncInFlight: syncing || _workerSyncStarting || _travelFetchRunning,
      mode: settings.scanCacheMode,
      outsideCacheArea: outside,
      deviceLat: lat,
      deviceLng: lng,
      lastFetchLat: newest?.latitude,
      lastFetchLng: newest?.longitude,
      lastFetchAt: newest == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              newest.fetchedAtMillis,
              isUtc: true,
            ),
      now: DateTime.now().toUtc(),
    );
    if (!decision.fetch) return false;
    final api = WorkerApi(
      AppConfig.deployedWorkerUrl,
      fallbackBaseUrl: AppConfig.fallbackWorkerUrl,
      staticDataBaseUrl: AppConfig.staticDataUrl,
    );
    if (!await api.canReach()) {
      _debugLog.info(
        'sync',
        'Skipped travel download because the network is down',
      );
      return false;
    }
    unawaited(_fetchTravelArea(lat, lng, api));
    return true;
  }

  Future<void> _fetchTravelArea(double lat, double lng, WorkerApi api) async {
    if (settings.forceOffline ||
        syncing ||
        _workerSyncStarting ||
        _travelFetchRunning) {
      return;
    }
    _travelFetchRunning = true;
    _workerSyncStarting = true;
    try {
      _debugLog.info(
        'sync',
        'Travel download within ${settings.travelRadiusMiles} mi',
      );
      _syncService.beginSync();
      final connectedRadioId = _connectedRadioMeshId8();
      final workerScans = await api.fetchRawScans(
        historyDays: settings.historyDays,
        deadzoneDays: settings.deadzoneDays,
        connectedRadioId: connectedRadioId,
        centerLat: lat,
        centerLng: lng,
        radiusMiles: settings.travelRadiusMiles,
        markDownloaded: true,
      );
      final prepared = await runOffUi(prepareRawScansWorker, <String, Object?>{
        'scans': workerScans,
        'connectedRadioId': connectedRadioId,
        'sanitizeDeadzoneRadios': true,
      }, weight: workerScans.length);
      final merged = await runOffUi(
        mergeWorkerAndLocalScansWorker,
        <String, Object?>{
          'workerScans': prepared.scans,
          'localScans': rawScans,
        },
        weight: prepared.scans.length + rawScans.length,
      );
      rawScans = merged.scans;
      await _rememberTravelCenter(lat, lng);
      rawScans = await _prunedForCacheArea(rawScans);
      _localStampDirty = false;
      await _localStore.saveRawScans(rawScans);
      await _rebuildDerivedData();
      _syncService.completeSync(workerScans.length);
    } catch (error) {
      _debugLog.error('sync', 'Travel download failed: $error');
      _syncService.failSync(error.toString());
      await _pruneCacheAndPersist();
    } finally {
      _travelFetchRunning = false;
      _workerSyncStarting = false;
      notifyListeners();
    }
  }

  Future<List<RawScan>> _downloadCloudScans(
    WorkerApi api,
    CloudFetchQuery query,
    String? connectedRadioId,
    bool Function() cancelled,
  ) {
    _logWorkerRadiusCap(query);
    return api.fetchRawScans(
      historyDays: settings.historyDays,
      deadzoneDays: settings.deadzoneDays,
      connectedRadioId: connectedRadioId,
      centerLat: query.latitude,
      centerLng: query.longitude,
      radiusMiles: query.omitsRadius ? null : query.radiusMiles,
      minLatitude: query.minLatitude,
      maxLatitude: query.maxLatitude,
      minLongitude: query.minLongitude,
      maxLongitude: query.maxLongitude,
      markDownloaded: true,
      onDayProgress: (done, total) {
        historyLoadLabel = 'Loading history $done/$total days';
        notifyListeners();
      },
      isCancelled: cancelled,
    );
  }

  Future<void> syncFromWorker() async {
    if (syncing || _workerSyncStarting || _travelFetchRunning) return;
    _workerSyncStarting = true;
    var refetchWhenFixArrives = false;
    try {
      final token = ++_historyLoadToken;
      final allDays = requestsAllDays(
        historyDays: settings.historyDays,
        deadzoneDays: settings.deadzoneDays,
      );
      _lastWorkerSyncSucceeded = false;
      bool cancelled() => token != _historyLoadToken;

      if (allDays && !settings.forceOffline) {
        await _allDaysGuard.arm();
        if (cancelled() &&
            !requestsAllDays(
              historyDays: settings.historyDays,
              deadzoneDays: settings.deadzoneDays,
            )) {
          await _allDaysGuard.clear();
          return;
        }
        if (cancelled()) return;
      }

      _debugLog.info('sync', 'Starting worker sync');
      _syncService.beginSync();
      try {
        if (cancelled()) throw const HistoryLoadCancelled();
        if (settings.forceOffline) {
          _debugLog.warn(
            'sync',
            'Skipped worker sync because offline mode is enabled',
          );
          _lastWorkerSyncSucceeded = true;
          _syncService.completeSync(0);
          return;
        }

        final api = WorkerApi(
          AppConfig.deployedWorkerUrl,
          fallbackBaseUrl: AppConfig.fallbackWorkerUrl,
          staticDataBaseUrl: AppConfig.staticDataUrl,
        );
        final connectedRadioId = _connectedRadioMeshId8();
        _applyLocalStamp();
        final localOnlyBeforeSync = rawScans
            .where((scan) => !scan.downloadedFromWorker)
            .toList(growable: false);
        if (localOnlyBeforeSync.isNotEmpty) {
          await _uploadPendingScans(api, localOnlyBeforeSync);
        }
        if (cancelled()) throw const HistoryLoadCancelled();

        final fetchWatch = Stopwatch()..start();
        meshStageStart('sync_fetch', count: settings.historyDays);
        // WorkerApi has no `since` cursor. The day window is unchanged.
        // The cache area chooses the geographic query. Division mode and a
        // radius above 250 miles also send a bounding box. Rows are still
        // pruned to the real outlines or radius after the merge. An older
        // worker ignores the box and clamps radius at 250 miles.
        final homeQuery = await _homeCloudQuery();
        final travelQuery = await _travelQueryDuringSync();
        refetchWhenFixArrives =
            homeQuery.skip &&
            clampScanCacheMode(settings.scanCacheMode) == scanCacheModeRadius &&
            _scanCacheCenterLat() == null;
        final workerScans = <RawScan>[];
        if (homeQuery.skip && travelQuery == null) {
          _debugLog.info(
            'sync',
            'Skipped cloud download for this cache area. '
                'Own scans stay on the device.',
          );
        }
        if (!homeQuery.skip) {
          workerScans.addAll(
            await _downloadCloudScans(
              api,
              homeQuery,
              connectedRadioId,
              cancelled,
            ),
          );
        }
        if (cancelled()) throw const HistoryLoadCancelled();
        if (travelQuery != null) {
          workerScans.addAll(
            await _downloadCloudScans(
              api,
              travelQuery,
              connectedRadioId,
              cancelled,
            ),
          );
          await _rememberTravelCenter(
            travelQuery.latitude!,
            travelQuery.longitude!,
          );
        }
        meshStageEnd(
          'sync_fetch',
          count: workerScans.length,
          ms: fetchWatch.elapsedMilliseconds,
        );
        if (cancelled()) throw const HistoryLoadCancelled();

        final prepareWatch = Stopwatch()..start();
        meshStageStart('sync_prepare', count: workerScans.length);
        final workerPrepared =
            await runOffUi(prepareRawScansWorker, <String, Object?>{
              'scans': workerScans,
              'connectedRadioId': connectedRadioId,
              'sanitizeDeadzoneRadios': true,
            }, weight: workerScans.length);
        meshStageEnd(
          'sync_prepare',
          count: workerPrepared.scans.length,
          ms: prepareWatch.elapsedMilliseconds,
        );
        _logSuppressedDeadzoneRows(workerPrepared.suppressedRows, 'worker');
        if (workerPrepared.suppressedHexes.isNotEmpty) {
          await _cleanupWorkerDeadzoneRows(api, workerPrepared.suppressedHexes);
        }
        if (cancelled()) throw const HistoryLoadCancelled();

        if (workerPrepared.scans.isNotEmpty) {
          final travelPreserve = await _scanCache.preservedTravelScans(
            scans: rawScans,
            settings: settings,
            centerLat: _scanCacheCenterLat(),
            centerLng: _scanCacheCenterLng(),
          );
          final localForMerge = <RawScan>[
            ...localOnlyBeforeSync,
            ...travelPreserve,
          ];
          final mergeWatch = Stopwatch()..start();
          meshStageStart(
            'sync_merge',
            count: workerPrepared.scans.length,
            n2: localForMerge.length,
          );
          final merged = await runOffUi(
            mergeWorkerAndLocalScansWorker,
            <String, Object?>{
              'workerScans': workerPrepared.scans,
              'localScans': localForMerge,
            },
            weight: workerPrepared.scans.length + localForMerge.length,
          );
          meshStageEnd(
            'sync_merge',
            count: merged.scans.length,
            ms: mergeWatch.elapsedMilliseconds,
          );
          if (cancelled()) throw const HistoryLoadCancelled();
          rawScans = merged.scans;
          _debugLog.info(
            'sync',
            'Fetched ${workerPrepared.scans.length} raw scans from worker',
          );
          _logSuppressedDeadzoneRows(merged.suppressedRows, 'merged');
          _debugLog.info(
            'sync',
            'Merged ${workerPrepared.scans.length} worker scans with '
                '${merged.preservedLocal} preserved local scan(s) '
                '=> ${rawScans.length} total',
          );
          _applyKnownContactsBackfill();
          if (cancelled()) throw const HistoryLoadCancelled();
        }

        var zonesFromWorker = false;
        final coverageWatch = Stopwatch()..start();
        meshStageStart('sync_coverage');
        try {
          if (homeQuery.skip) {
            _debugLog.info(
              'sync',
              'Skipped coverage download for this cache area',
            );
            meshStageEnd(
              'sync_coverage',
              count: 0,
              ms: coverageWatch.elapsedMilliseconds,
            );
          } else {
            final workerZones = await api.fetchCoverageZones(
              historyDays: settings.historyDays,
              deadzoneDays: settings.deadzoneDays,
              connectedRadioId: connectedRadioId,
              centerLat: homeQuery.latitude,
              centerLng: homeQuery.longitude,
              radiusMiles: homeQuery.omitsRadius ? null : homeQuery.radiusMiles,
              minLatitude: homeQuery.minLatitude,
              maxLatitude: homeQuery.maxLatitude,
              minLongitude: homeQuery.minLongitude,
              maxLongitude: homeQuery.maxLongitude,
            );
            if (cancelled()) throw const HistoryLoadCancelled();
            final preparedZones = await runOffUi(
              prepareCoverageZonesWorker,
              <String, Object?>{
                'zones': workerZones,
                'connectedRadioId': connectedRadioId,
              },
              weight: workerZones.length,
            );
            if (cancelled()) throw const HistoryLoadCancelled();
            _debugLog.info(
              'sync',
              'Fetched ${workerZones.length} coverage zones from worker',
            );
            if (preparedZones.suppressedRows > 0) {
              _debugLog.info(
                'sync',
                'Suppressed ${preparedZones.suppressedRows} deadzone coverage '
                    'row(s) in successful hexes (worker)',
              );
            }
            coverageZones = preparedZones.zones;
            zonesFromWorker = true;
            meshStageEnd(
              'sync_coverage',
              count: preparedZones.zones.length,
              ms: coverageWatch.elapsedMilliseconds,
            );
          }
        } on HistoryLoadCancelled {
          meshStageEnd(
            'sync_coverage',
            count: 0,
            ms: coverageWatch.elapsedMilliseconds,
          );
          rethrow;
        } catch (_) {
          meshStageEnd(
            'sync_coverage',
            count: 0,
            ms: coverageWatch.elapsedMilliseconds,
          );
          _debugLog.warn(
            'sync',
            'Coverage zones endpoint failed, falling back to local aggregation',
          );
        }

        if (cancelled()) throw const HistoryLoadCancelled();
        final beforePrune = rawScans;
        rawScans = await _prunedForCacheArea(rawScans);
        if (cancelled()) throw const HistoryLoadCancelled();
        if (!identical(rawScans, beforePrune) ||
            _localStampDirty ||
            workerPrepared.scans.isNotEmpty) {
          _localStampDirty = false;
          await _localStore.saveRawScans(rawScans);
        }
        final keepWorkerZones =
            zonesFromWorker &&
            !scanCacheWillFilter(
              mode: settings.scanCacheMode,
              centerLat: _scanCacheCenterLat(),
              centerLng: _scanCacheCenterLng(),
            );
        await _rebuildDerivedData(skipZones: keepWorkerZones);
        if (allDays && !cancelled()) {
          await _allDaysGuard.clear();
        }
        _lastWorkerSyncSucceeded = true;
        _syncService.captureInternetTimeAnchor(api.lastServerDateUtc);
        final internetNow = _syncService.estimatedInternetNowUtc();
        if (internetNow != null) {
          _syncService.recordPeriodicSyncTime(internetNow);
        }
        _syncService.completeSync(workerScans.length);
      } on HistoryLoadCancelled {
        _debugLog.info('sync', 'History load cancelled');
        await _rebuildDerivedData();
        _syncService.abandonSync();
      } catch (e) {
        _debugLog.error('sync', 'Worker sync failed: $e');
        await _rebuildDerivedData();
        _syncService.failSync(e.toString());
      } finally {
        historyLoadLabel = null;
        _debugLog.info('sync', 'Worker sync finished');
        meshStage(
          'sync_finish',
          event: 'end',
          count: rawScans.length,
          n2: coverageZones.length,
        );
        notifyListeners();
      }
    } finally {
      _workerSyncStarting = false;
      if (refetchWhenFixArrives &&
          _scanCacheCenterLat() != null &&
          !settings.forceOffline) {
        unawaited(syncFromWorker());
      } else if (_expandDuringSync && !settings.forceOffline) {
        _expandDuringSync = false;
        _pruneAfterSync = false;
        unawaited(syncFromWorker());
      } else if (_pruneAfterSync) {
        _pruneAfterSync = false;
        unawaited(_pruneCacheAndPersist());
      }
    }
  }

  /// [interactive] false is the screen-off reconnect path. It does not show
  /// permission dialogs, open settings, or wait on a PIN prompt.
  Future<bool> connectBle({bool interactive = true}) async {
    if (!await _ensureBleAvailable(context: 'ble', prompt: interactive)) {
      return false;
    }
    if (!await _locationService.ensureAndroidReadyForBle(prompt: interactive)) {
      return false;
    }
    if (bleConnecting || bleConnected) return bleConnected;
    if (bleSelectedDeviceId == null || bleSelectedDeviceId!.isEmpty) {
      bleStatus = 'Select a BLE device first';
      notifyListeners();
      return false;
    }
    if (interactive) {
      _manualBleDisconnectRequested = false;
    } else if (_manualBleDisconnectRequested) {
      _debugLog.info(
        'ble',
        'Background reconnect skipped because the user disconnected',
      );
      return false;
    }
    if (_transport is BleTransport) {
      (_transport).preferredDeviceId = bleSelectedDeviceId;
    }
    _debugLog.info(
      'ble',
      interactive ? 'Connect requested' : 'Background reconnect connect',
    );
    bleConnecting = true;
    if (_transport is BleTransport) {
      await _transport.stopDeviceScan();
      bleDeviceScanInProgress = false;
    }
    bleStatus = 'BLE connecting...';
    notifyListeners();

    var ok = false;
    try {
      if (_transport is BleTransport) {
        await _transport.connect(allowPermissionPrompt: interactive);
      } else {
        await _transport.connect();
      }
      await _completeBleConnectSuccess();
      ok = bleConnected && _transport.isConnected;
    } catch (e) {
      bleConnected = false;
      final lowered = e.toString().toLowerCase();
      var handledAsBluetoothOff = false;
      if (lowered.contains('bluetooth is not powered on') ||
          lowered.contains('bluetooth_not_enabled') ||
          lowered.contains('bluetoothnoten') ||
          lowered.contains('poweredoff')) {
        handledAsBluetoothOff = true;
        await _handleBleUnavailableState(
          state: AvailabilityState.poweredOff,
          context: 'ble_connect',
          prompt: interactive,
        );
      }
      var recovered = false;
      if (!handledAsBluetoothOff &&
          _isDeviceNotFoundConnectError(e) &&
          !kIsWeb &&
          (interactive || !_manualBleDisconnectRequested)) {
        recovered = await _recoverConnectAfterDeviceNotFound();
      }
      if (recovered) {
        ok = bleConnected && _transport.isConnected;
      } else {
        _debugLog.error('ble', 'Connect failed: $e');
        if (!handledAsBluetoothOff) {
          if (_isDeviceNotFoundConnectError(e)) {
            bleStatus = 'Device not found – is your radio powered on?';
          } else {
            bleStatus = 'BLE connect failed';
          }
        }
        ok = false;
      }
    } finally {
      bleConnecting = false;
      notifyListeners();
    }
    return ok;
  }

  Future<void> _completeBleConnectSuccess() async {
    bleConnected = _transport.isConnected;
    if (!bleConnected) {
      throw StateError('BLE connect returned without an active transport link');
    }
    _startPassiveAdvertListener();
    final selectedName = cleanRadioDisplayName(_selectedBleDeviceName());
    if (selectedName.isNotEmpty) {
      _connectedRadioDisplayName = selectedName;
    }
    _debugLog.info(
      'ble',
      'Connected via ${selectedName.isNotEmpty ? selectedName : _transport.name}',
    );
    final selectedId = (bleSelectedDeviceId ?? '').trim();
    bleStatus = selectedName.isNotEmpty
        ? (selectedId.isNotEmpty
              ? 'Connected ($selectedName [$selectedId])'
              : 'Connected ($selectedName)')
        : (selectedId.isNotEmpty ? 'Connected [$selectedId]' : 'Connected');
    final nextKnownIds =
        settings.knownBleDeviceIds.contains(selectedId) || selectedId.isEmpty
        ? settings.knownBleDeviceIds
        : [...settings.knownBleDeviceIds, selectedId];
    final nextKnownNames = Map<String, String>.from(
      settings.knownBleDeviceNames,
    );
    if (selectedId.isNotEmpty &&
        selectedName.isNotEmpty &&
        !_isPlaceholderBleDeviceName(selectedName)) {
      nextKnownNames[selectedId] = selectedName;
    }
    final knownIdsChanged = !listEquals(
      nextKnownIds,
      settings.knownBleDeviceIds,
    );
    final knownNamesChanged = !mapEquals(
      nextKnownNames,
      settings.knownBleDeviceNames,
    );
    if (knownIdsChanged || knownNamesChanged) {
      await updateSettings(
        settings.copyWith(
          knownBleDeviceIds: nextKnownIds,
          knownBleDeviceNames: nextKnownNames,
        ),
      );
    }
    await _requestSelfInfo();
    await _maybeLoadRadioSettings();
    await _syncContactsAndBackfillNames();
    await _applyCompanionLocationPolicyFromSettings();
  }

  bool _isDeviceNotFoundConnectError(Object error) {
    final lowered = error.toString().toLowerCase();
    return lowered.contains('device_not_found') ||
        lowered.contains('unknown deviceid') ||
        lowered.contains('universalbleerrorcode.devicenotfound') ||
        lowered.contains('devicenotfound');
  }

  Future<bool> _recoverConnectAfterDeviceNotFound() async {
    if (_transport is! BleTransport) return false;
    final ble = _transport;
    final targetDeviceId = (bleSelectedDeviceId ?? '').trim();
    if (targetDeviceId.isEmpty) return false;
    _debugLog.warn(
      'ble',
      'Connect failed with device-not-found for $targetDeviceId; '
          'running refresh scan and retrying once',
    );
    bleStatus = 'Refreshing BLE device list...';
    notifyListeners();
    try {
      await ble.resetLinkState(deviceId: targetDeviceId);
    } catch (resetError) {
      _debugLog.warn('ble', 'Recovery link-state reset failed: $resetError');
    }
    try {
      await ble.scanDevices(timeout: const Duration(seconds: 3));
    } catch (scanError) {
      _debugLog.warn('ble', 'Recovery scan failed: $scanError');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      await _bleProtocol.run(_protocol.connect());
      await _completeBleConnectSuccess();
      _debugLog.info(
        'ble',
        'Recovery connect succeeded after scan refresh target=$targetDeviceId',
      );
      return true;
    } catch (scanRetryError) {
      _debugLog.warn(
        'ble',
        'Recovery connect after scan failed: $scanRetryError; '
            'trying direct BlueZ connect',
      );
    }

    // Last resort: ask bluetoothctl to connect directly (works for
    // previously-paired devices that BlueZ still has cached even though
    // they weren't discovered in the scan).
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      bleStatus = 'Trying direct BlueZ connect...';
      notifyListeners();
      final directOk = await ble.tryDirectBlueZConnect(targetDeviceId);
      if (directOk) {
        // Device is now connected at the BlueZ level; re-discover & bind.
        try {
          await _bleProtocol.run(_protocol.connect());
          await _completeBleConnectSuccess();
          _debugLog.info(
            'ble',
            'Recovery connect succeeded via direct BlueZ connect '
                'target=$targetDeviceId',
          );
          return true;
        } catch (directRetryError) {
          _debugLog.error(
            'ble',
            'Recovery connect failed after direct BlueZ connect '
                'target=$targetDeviceId: $directRetryError',
          );
        }
      }
    }
    bleConnected = false;
    return false;
  }

  Future<void> disconnectBle() async {
    _debugLog.info('ble', 'Disconnect requested');
    _manualBleDisconnectRequested = true;
    _scanLoopWanted = false;
    _resumeAutoScanAfterReconnect = false;
    _cancelScanLoopReconnect('manual disconnect');
    bleBusy = false;
    bleConnecting = false;
    bleScanning = false;
    bleScanStatus = 'idle';
    _bleAutoScanTimer?.cancel();
    _bleCountdownTimer?.cancel();
    _resetAutoScanSchedule();
    _smartScanPausedForRecentCoverage = false;
    _smartScanPausedZoneId = null;
    _stopPassiveAdvertListener();
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
    _sessionRadioContacts.clear();
    _invalidateSessionContactLookup();
    // Keep a sync that already finished as disconnected. The link callback
    // completes that sync before this line runs.
    if (contactsSyncProgress.active && !contactsSyncProgress.disconnected) {
      contactsSyncProgress = ContactSyncProgress.idle;
    }
    _sessionRadioContactTypes.clear();
    _syncAndroidScanForeground();
    notifyListeners();
  }

  void selectBleDevice(String deviceId) {
    if (bleSelectedDeviceId == deviceId) {
      _debugLog.debug('ble', 'BLE device already selected: $deviceId');
      if (kIsWeb && !bleConnected && !bleConnecting) {
        _debugLog.info('ble', 'Retrying web BLE connect for selected device');
        unawaited(connectBle());
      }
      return;
    }
    bleSelectedDeviceId = deviceId;
    if (_transport is BleTransport) {
      (_transport).preferredDeviceId = deviceId;
    }
    _debugLog.info('ble', 'Selected BLE device: $deviceId');
    bleStatus = 'Selected device: $deviceId';
    notifyListeners();
    if (kIsWeb && !bleConnected && !bleConnecting) {
      _debugLog.info('ble', 'Auto-connecting selected web BLE device');
      unawaited(connectBle());
    }
  }

  Future<void> scanBleDevices() async {
    if (!kIsWeb) {
      if (!await _ensureBleAvailable(context: 'ble_scan')) {
        return;
      }
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
    bleStatus = kIsWeb
        ? 'Choose a radio in the browser Bluetooth picker...'
        : 'Scanning BLE devices...';
    _webAutoConnectAttemptedDeviceId = null;
    if (!kIsWeb) {
      bleScanDevices = const [];
      _seedKnownBleScanDevices();
      _primePreferredBleDeviceForScan();
    }
    notifyListeners();
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final selected = (bleSelectedDeviceId ?? '').trim();
        if (selected.isNotEmpty) {
          await ble.resetLinkState(deviceId: selected);
        }
      }
      await ble.scanDevices();
      if (bleConnected || bleConnecting) {
        return;
      }
      if (kIsWeb) {
        final selected = (bleSelectedDeviceId ?? '').trim();
        if (selected.isNotEmpty) {
          _debugLog.info(
            'ble',
            'Web picker selected device $selected; ensuring connect',
          );
          await connectBle();
          return;
        }
        bleStatus = 'No radio selected in browser picker';
        return;
      }
      bleStatus = bleScanDevices.isEmpty
          ? 'No BLE devices found'
          : 'Tap a BLE device from results to connect';
    } catch (e) {
      final message = e.toString();
      if (kIsWeb &&
          (message.contains('DeviceNotFoundError') ||
              message.contains('No device selected'))) {
        bleStatus = 'No radio selected in browser picker';
      } else if (kIsWeb &&
          (message.contains('NotAllowedError') ||
              message.contains('user gesture') ||
              message.contains('User cancelled'))) {
        bleStatus =
            'Browser blocked Bluetooth request. Tap Connect Device again.';
      } else if (message.contains('bluetoothNotEnabled') ||
          message.contains('BLUETOOTH_NOT_ENABLED')) {
        await _handleBleUnavailableState(
          state: AvailabilityState.poweredOff,
          context: 'ble_scan',
        );
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
    final discoverStartedAt = DateTime.now();
    _debugLog.info('ble_discover', 'node_discover requested');
    if (!bleConnected) {
      await connectBle();
      if (!bleConnected) return;
    }

    if (bleBusy) return;
    bleBusy = true;
    final autoLoopOwnsCountdown = bleScanning;
    bleScanStatus = 'advertising';
    bleStatus = 'Discovery Sent';
    bleDiscoveries = const [];
    bleLastDiscoverError = null;
    _bleCountdownTimer?.cancel();
    if (!autoLoopOwnsCountdown) {
      bleNextScanCountdown = discoverWait.inSeconds;
    }
    notifyListeners();

    final byPrefix = <String, NodeDiscoverResponse>{};
    final directDiscoverPrefixes = <String>{};
    late final StreamSubscription<NodeDiscoverResponse> discoverSub;
    late final StreamSubscription<NodeDiscoverAdvertResponse> advertSub;
    late final StreamSubscription<Uint8List> rawSub;
    DateTime? firstResponseAt;
    DateTime? lastResponseAt;
    const autoScanQuietWindow = Duration(milliseconds: 1800);

    discoverSub = _bleProtocol.nodeDiscoverResponses().listen((response) {
      final resolvedName = _resolveDiscoverName(
        nodeId: response.publicKeyPrefix,
        incomingName: response.name,
      );
      directDiscoverPrefixes.add(response.publicKeyPrefix);
      byPrefix[response.publicKeyPrefix] = resolvedName.isEmpty
          ? response
          : NodeDiscoverResponse(
              snr: response.snr,
              rssi: response.rssi,
              snrIn: response.snrIn,
              nodeType: response.nodeType,
              tagHex: response.tagHex,
              publicKeyPrefix: response.publicKeyPrefix,
              name: resolvedName,
            );
      final responseAt = DateTime.now();
      firstResponseAt ??= responseAt;
      lastResponseAt = responseAt;
      unawaited(_locationService.refreshForDiscoverResponse());
      bleDiscoveries = byPrefix.values.toList();
      _debugLog.debug(
        'ble_discover',
        'Response ${response.publicKeyPrefix} RSSI=${response.rssi} SNR=${response.snr}',
      );
      bleStatus = _discoverStatusLine(
        nodeId: response.publicKeyPrefix,
        name: displayNameForNode(
          response.publicKeyPrefix,
          advertisedName: resolvedName,
        ),
        rssi: response.rssi,
        snr: response.snr,
      );
      notifyListeners();
    });
    advertSub = _bleProtocol.nodeDiscoverAdvertResponses().listen((advert) {
      _cacheAdvertName(
        nodeId: advert.publicKeyPrefix,
        name: advert.name,
        source: 'discover',
      );
      unawaited(
        _upsertHeardContact(
          prefix: advert.publicKeyPrefix,
          name: advert.name,
          type: advert.nodeType,
          source: 'advert',
        ),
      );
      final resolvedAdvertName = _resolveDiscoverName(
        nodeId: advert.publicKeyPrefix,
        incomingName: advert.name,
      );
      final existing = byPrefix[advert.publicKeyPrefix];
      if (existing == null) {
        byPrefix[advert.publicKeyPrefix] = NodeDiscoverResponse(
          snr: 0,
          rssi: 0,
          snrIn: 0,
          nodeType: advert.nodeType,
          tagHex: '',
          publicKeyPrefix: advert.publicKeyPrefix,
          name: resolvedAdvertName,
        );
      } else if (resolvedAdvertName.isNotEmpty &&
          existing.name.trim() != resolvedAdvertName) {
        byPrefix[advert.publicKeyPrefix] = NodeDiscoverResponse(
          snr: existing.snr,
          rssi: existing.rssi,
          snrIn: existing.snrIn,
          nodeType: existing.nodeType,
          tagHex: existing.tagHex,
          publicKeyPrefix: existing.publicKeyPrefix,
          name: resolvedAdvertName,
        );
      }
      final responseAt = DateTime.now();
      firstResponseAt ??= responseAt;
      lastResponseAt = responseAt;
      unawaited(_locationService.refreshForDiscoverResponse());
      bleDiscoveries = byPrefix.values.toList();
      _debugLog.debug(
        'ble_discover',
        'Advert ${advert.publicKeyPrefix} name=$resolvedAdvertName',
      );
      bleStatus = _discoverStatusLine(
        nodeId: advert.publicKeyPrefix,
        name: displayNameForNode(
          advert.publicKeyPrefix,
          advertisedName: resolvedAdvertName,
        ),
      );
      notifyListeners();
    });
    rawSub = _transport.inbound.listen((frame) {
      final parsedControl = parseNodeDiscoverResponse(frame);
      final parsedAdvert = parseNodeDiscoverAdvertResponse(frame);
      if (parsedControl != null || parsedAdvert != null) {
        return;
      }
      final code = frame.isNotEmpty ? frame.first : -1;
      final codeName = _frameCodeName(code);
      if (code == respCodeOk) {
        _debugLog.debug(
          'ble_discover_diag',
          'node_discover ack received ($codeName)',
        );
        return;
      }
      final headBytes = frame.length > 12 ? frame.sublist(0, 12) : frame;
      final headHex = headBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      _debugLog.debug(
        'ble_discover_diag',
        code == pushCodeLogRxData
            ? 'RX frame code=0x${code.toRadixString(16)} '
                  '($codeName) len=${frame.length} head=$headHex'
            : 'RX activity frame code=0x${code.toRadixString(16)} '
                  '($codeName) len=${frame.length} head=$headHex',
      );
    });

    var retryDiscoverAfterReconnect = false;
    try {
      // Display only. The listen clock still starts when the send returns.
      _beginCountdownAtDiscoverSend(
        autoLoopOwnsCountdown: autoLoopOwnsCountdown,
        discoverWait: discoverWait,
      );
      await _sendNodeDiscoverCommand();
      bleScanStatus = 'waiting';
      final start = DateTime.now();
      final deadline = start.add(discoverWait);
      final initialWaitDeadline = start.add(const Duration(seconds: 10));
      var resentDiscover = false;
      while (true) {
        final now = DateTime.now();
        if (!now.isBefore(deadline)) break;

        if (byPrefix.isEmpty && !now.isBefore(initialWaitDeadline)) {
          _debugLog.info(
            'ble_discover',
            'No responses after initial 10s wait; finishing early',
          );
          break;
        }

        if (!bleConnected || !_transport.isConnected) {
          throw StateError('BLE disconnected during node_discover');
        }
        if (autoLoopOwnsCountdown &&
            byPrefix.isNotEmpty &&
            lastResponseAt != null) {
          final quietFor = now.difference(lastResponseAt!);
          if (quietFor >= autoScanQuietWindow) {
            final firstResponseMs = firstResponseAt == null
                ? 'n/a'
                : firstResponseAt!.difference(start).inMilliseconds;
            _debugLog.info(
              'ble_discover',
              'Auto loop quiet window reached; finishing early '
                  'responses=${byPrefix.length} '
                  'firstResponseMs=$firstResponseMs '
                  'quietMs=${quietFor.inMilliseconds} '
                  'elapsedMs=${now.difference(start).inMilliseconds}',
            );
            break;
          }
        }
        if (!resentDiscover &&
            byPrefix.isEmpty &&
            now.difference(start).inMilliseconds >=
                discoverWait.inMilliseconds ~/ 2) {
          resentDiscover = true;
          _debugLog.info(
            'ble_discover',
            'No responses yet; resending node_discover once',
          );
          await _sendNodeDiscoverCommand();
        }
        final remainingMs = deadline.difference(now).inMilliseconds;
        final sliceMs = remainingMs > 250 ? 250 : remainingMs;
        if (sliceMs <= 0) break;
        await Future<void>.delayed(Duration(milliseconds: sliceMs));
      }
      _bleCountdownTimer?.cancel();
      final persistedDiscoverResponses = byPrefix.values.where(
        (response) => directDiscoverPrefixes.contains(response.publicKeyPrefix),
      );
      final appended = await _appendDiscoverScansWithOsLocation(
        persistedDiscoverResponses,
      );
      if (appended > 0) {
        await _localStore.saveRawScans(rawScans);
        await _rebuildDerivedData();
        _debugLog.info(
          'ble_discover',
          'Stored $appended local scan(s) with OS location',
        );
      } else if (byPrefix.isEmpty) {
        final recorded = _recordDeadZoneScan();
        if (recorded) {
          await _localStore.saveRawScans(rawScans);
          await _rebuildDerivedData();
        }
      }
      bleScanStatus = 'done';
      if (bleDiscoveries.isEmpty) {
        bleStatus = 'Discovery Complete (No Responses)';
      } else {
        final last = bleDiscoveries.last;
        bleStatus = _discoverStatusLine(
          nodeId: last.publicKeyPrefix,
          name: last.name,
          rssi: last.rssi,
          snr: last.snr,
        );
      }
      _debugLog.info(
        'ble_discover',
        'Completed with ${bleDiscoveries.length} response(s) '
            'elapsedMs=${DateTime.now().difference(discoverStartedAt).inMilliseconds}',
      );
      bleLastDiscoverCount = bleDiscoveries.length;
      bleLastDiscoverAt = DateTime.now();
      if (!autoLoopOwnsCountdown) {
        bleNextScanCountdown = null;
      }
    } catch (e) {
      bleScanStatus = 'error';
      bleStatus = 'node_discover failed: $e';
      _debugLog.error(
        'ble_discover',
        'Failed: $e elapsedMs=${DateTime.now().difference(discoverStartedAt).inMilliseconds}',
      );
      bleLastDiscoverError = e.toString();
      if (!autoLoopOwnsCountdown) {
        bleNextScanCountdown = null;
      }
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
      _bleCountdownTimer?.cancel();
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

  Future<int> _appendDiscoverScansWithOsLocation(
    Iterable<NodeDiscoverResponse> responses,
  ) async {
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
      final nodeId8 = safePublicRadioId(response.publicKeyPrefix);
      if (nodeId8 == null || nodeId8.isEmpty) {
        _debugLog.warn(
          'scan_store',
          'Skipping discover response with unsafe node id: ${response.publicKeyPrefix}',
        );
        continue;
      }
      final responseName = response.name.trim();
      // Prefer a repeater/room contact name when present. Advertised names
      // still win over a raw id. Companion/chat contact names are never used.
      final senderName = _resolveScanSenderName(
        nodeId: response.publicKeyPrefix,
        advertisedName: responseName,
      );
      final hasAdvertName =
          responseName.isNotEmpty &&
          !isPlaceholderNodeName(responseName, response.publicKeyPrefix);
      _debugLog.debug(
        'contacts',
        _contactsMatchLog(
          nodeId: nodeId8,
          matched:
              _bestContactNameForId(
                _sessionRadioContacts,
                response.publicKeyPrefix,
              ) !=
              null,
          hasAdvertName: hasAdvertName,
        ),
      );
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
        senderName: senderName,
        receiverName: (_connectedRadioDisplayName ?? '').trim().isEmpty
            ? connectedMeshId8
            : _connectedRadioDisplayName!.trim(),
        radioId: connectedMeshId8,
        downloadedFromWorker: false,
        locallyRecorded: true,
      );
      appended.add(normalizeRawScanIds(scan));
      _debugLog.info(
        'scan_store',
        'radio=${scan.radioId ?? 'unknown'} node=${scan.nodeId} '
            'lat=${lat.toStringAsFixed(6)} '
            'lng=${lng.toStringAsFixed(6)} rssi=${scan.rssi?.toStringAsFixed(1)}',
      );
    }
    if (appended.isNotEmpty) {
      final combined = <RawScan>[...appended, ...rawScans];
      final prepared = await runOffUi(prepareRawScansWorker, <String, Object?>{
        'scans': combined,
      }, weight: combined.length);
      rawScans = prepared.scans;
      if (prepared.suppressedRows > 0) {
        _debugLog.info(
          'scan_store',
          'Deleted ${prepared.suppressedRows} local deadzone row(s) '
              'after successful discover scan(s)',
        );
      }
    }
    return appended.length;
  }

  /// Records a synthetic dead-zone [RawScan] at the current GPS location
  /// when a node_discover completes with zero responses.
  bool _recordDeadZoneScan() {
    final lat = deviceLatitude;
    final lng = deviceLongitude;
    if (lat == null || lng == null) {
      _debugLog.warn(
        'dead_zone',
        'No OS location fix; skipping dead-zone scan',
      );
      return false;
    }
    if (_hexHasSuccessfulCoverage(lat, lng)) {
      _debugLog.info(
        'dead_zone',
        'Skipping dead-zone scan; hex already has successful coverage',
      );
      return false;
    }
    final connectedMeshId8 = _connectedRadioMeshId8();
    if (connectedMeshId8 == null || connectedMeshId8.isEmpty) {
      _debugLog.warn(
        'dead_zone',
        'No connected radio ID; skipping dead-zone scan',
      );
      return false;
    }
    final now = DateTime.now();
    final scan = normalizeRawScanIds(
      RawScan(
        observerId: connectedMeshId8,
        nodeId: null,
        latitude: lat,
        longitude: lng,
        rssi: null,
        snr: null,
        altitude: deviceAltitude,
        timestamp: now,
        receivedAt: now,
        senderName: null,
        receiverName: (_connectedRadioDisplayName ?? '').trim().isEmpty
            ? connectedMeshId8
            : _connectedRadioDisplayName!.trim(),
        radioId: connectedMeshId8,
        downloadedFromWorker: false,
        locallyRecorded: true,
      ),
    );
    rawScans = [scan, ...rawScans];
    _debugLog.info(
      'dead_zone',
      'Recorded dead-zone scan radio=$connectedMeshId8 '
          'lat=${lat.toStringAsFixed(6)} lng=${lng.toStringAsFixed(6)}',
    );
    return true;
  }

  bool _hexHasSuccessfulCoverage(double lat, double lng) {
    final zoneId = hexKey(lat, lng);
    for (final scan in rawScans) {
      if (hexKey(scan.latitude, scan.longitude) != zoneId) continue;
      if (!isDeadLikeScan(scan)) return true;
    }
    return false;
  }

  Future<void> _syncContactsAndBackfillNames() async {
    if (!bleConnected) return;
    await _adoptPersistedContactsIntoSession();
    if (_transport is BleTransport) {
      await (_transport).preferHighThroughputLink();
    }
    _debugLog.warn('contacts', 'Requesting contacts from radio');

    final radioId = _connectedRadioMeshId8();
    var stored = <String, LocalContact>{};
    if (radioId != null && localContactsSupported) {
      stored = await _contactStore.loadContacts(radioId);
    }
    final initialSince = newestStoredLastMod(stored.values);
    var lastNotifiedReceived = -1;
    int? lastNotifiedExpected;

    contactsSyncProgress = ContactSyncProgress(
      active: true,
      received: stored.length,
    );
    notifyListeners();

    Future<void> persistBatch(List<SyncedContact> batch) async {
      if (batch.isEmpty) return;
      final names = {for (final c in batch) c.publicKeyPrefix: c.name};
      _pruneSelfContact(names);
      final kept = [
        for (final c in batch)
          if (names.containsKey(c.publicKeyPrefix)) c,
      ];
      if (kept.isEmpty) return;
      for (final c in kept) {
        _sessionRadioContacts[c.publicKeyPrefix] = c.name;
        _sessionRadioContactTypes[c.publicKeyPrefix] = c.type;
        _radioContactsByPrefix[c.publicKeyPrefix] = c.name;
      }
      _invalidateSessionContactLookup();
      final id = _connectedRadioMeshId8();
      // The book stays on device. Only REPEATER/ROOM names are eligible for
      // upload, and that gating is unchanged.
      if (id == null || !localContactsSupported) return;
      final now = DateTime.now().toUtc();
      try {
        await _contactStore.mergeContacts(id, [
          for (final c in kept)
            LocalContact(
              publicKeyPrefix: c.publicKeyPrefix,
              name: c.name,
              type: c.type,
              lastHeard: now,
              lastMod: c.lastMod > 0 ? c.lastMod : null,
              source: 'sync',
            ),
        ]);
      } catch (e) {
        _debugLog.warn('contacts', 'Incremental store merge failed: $e');
      }
    }

    final linkClosed = Completer<void>();
    _contactSyncLinkClosed = linkClosed;
    if (!bleConnected || !_transport.isConnected) {
      linkClosed.complete();
    }
    ContactSyncResult? result;
    try {
      result = await collectContactsFromInbound(
        inbound: _transport.inbound,
        sendGetContacts: (since) =>
            _bleProtocol.run(_protocol.getContacts(since: since)),
        initialSince: initialSince,
        linkClosed: linkClosed.future,
        seedContacts: {
          for (final c in stored.values) c.publicKeyPrefix: c.name,
        },
        seedTypes: {for (final c in stored.values) c.publicKeyPrefix: c.type},
        seedLastMods: {
          for (final c in stored.values)
            if (c.lastMod != null && c.lastMod! > 0)
              c.publicKeyPrefix: c.lastMod!,
        },
        onContacts: persistBatch,
        onProgress: (progress) {
          contactsSyncProgress = progress;
          final expectedChanged = progress.expected != lastNotifiedExpected;
          lastNotifiedExpected = progress.expected;
          final jumped =
              lastNotifiedReceived < 0 ||
              progress.received - lastNotifiedReceived >= 25 ||
              progress.received < lastNotifiedReceived;
          if (jumped ||
              expectedChanged ||
              progress.completed ||
              progress.incomplete ||
              progress.disconnected) {
            lastNotifiedReceived = progress.received;
            notifyListeners();
          }
        },
      );
    } finally {
      if (!linkClosed.isCompleted) linkClosed.complete();
      _contactSyncLinkClosed = null;
      final outcome = result?.outcome ?? ContactSyncOutcome.disconnected;
      final storedCount = result?.contacts.length ?? 0;
      contactsSyncProgress = ContactSyncProgress(
        active: false,
        received: storedCount,
        expected: result?.expectedTotal,
        completed: outcome == ContactSyncOutcome.completed,
        incomplete: outcome == ContactSyncOutcome.incomplete,
        disconnected: outcome == ContactSyncOutcome.disconnected,
      );
      notifyListeners();
      _debugLog.debug(
        'contacts',
        'frames=${result?.framesSeen ?? 0} stored=$storedCount '
            'expected=${result?.expectedTotal ?? -1} outcome=${outcome.name}',
      );
    }

    if (result.contacts.isEmpty) {
      _debugLog.warn('contacts', 'No contacts returned from radio');
      notifyListeners();
      _logKnownNodeContactMatches();
      return;
    }

    final contacts = result.contacts;
    final contactTypes = result.contactTypes;

    _radioContactsByPrefix.addAll(contacts);
    _updateConnectedRadioMeshIdFromContacts(contacts);

    final sessionContacts = Map<String, String>.from(contacts);
    _pruneSelfContact(sessionContacts);
    _pruneSelfContact(_radioContactsByPrefix);
    final sessionTypes = Map<String, int>.from(contactTypes)
      ..removeWhere((key, _) => !sessionContacts.containsKey(key));
    final sessionChanged = !mapEquals(_sessionRadioContacts, sessionContacts);
    final typesChanged = !mapEquals(_sessionRadioContactTypes, sessionTypes);
    if (sessionChanged || typesChanged) {
      _sessionRadioContacts
        ..clear()
        ..addAll(sessionContacts);
      _sessionRadioContactTypes
        ..clear()
        ..addAll(sessionTypes);
      _invalidateSessionContactLookup();
    }

    // Final merge covers anything still buffered and records lastmod for the
    // next resume. The book never leaves the device.
    final persistedRadioId = _connectedRadioMeshId8();
    if (persistedRadioId == null) {
      _debugLog.warn(
        'contacts',
        'Radio id unknown; keeping ${sessionContacts.length} contact(s) in memory only',
      );
    } else if (localContactsSupported) {
      final now = DateTime.now().toUtc();
      final lastMods = result.lastMods;
      int? keptLastMod(String key) {
        final value = lastMods[key];
        if (value == null || value <= 0) return null;
        return value;
      }

      final incoming = <LocalContact>[
        for (final e in sessionContacts.entries)
          LocalContact(
            publicKeyPrefix: e.key,
            name: e.value,
            type: sessionTypes[e.key] ?? 0,
            lastHeard: now,
            lastMod: keptLastMod(e.key),
            source: 'sync',
          ),
      ];
      final merged = await _contactStore.mergeContacts(
        persistedRadioId,
        incoming,
      );
      // Reflect full local book (includes previously heard companions).
      _sessionRadioContacts
        ..clear()
        ..addAll({for (final c in merged.values) c.publicKeyPrefix: c.name});
      _sessionRadioContactTypes
        ..clear()
        ..addAll({for (final c in merged.values) c.publicKeyPrefix: c.type});
      _invalidateSessionContactLookup();
      _debugLog.warn(
        'contacts',
        'Local store merge received=${sessionContacts.length} stored=${merged.length}',
      );
    }

    final updated = _backfillScanNamesFromContacts(_radioContactsByPrefix);
    if (updated > 0) {
      await _localStore.saveRawScans(rawScans);
      await _rebuildDerivedData();
    }
    notifyListeners();
    _debugLog.warn(
      'contacts',
      'Loaded ${contacts.length} contact(s), session ${sessionContacts.length}, updated $updated scan name field(s)',
    );
    _logKnownNodeContactMatches();
  }

  Future<void> _upsertHeardContact({
    required String prefix,
    required String name,
    required int type,
    String? path,
    String source = 'advert',
  }) async {
    final p = prefix.trim().toUpperCase();
    final n = name.trim();
    if (p.isEmpty) return;
    if (n.isNotEmpty) {
      _sessionRadioContacts[p] = n;
      _invalidateSessionContactLookup();
    }
    if (type != 0) {
      _sessionRadioContactTypes[p] = type;
    }
    final radioId = _connectedRadioMeshId8();
    if (radioId == null || !localContactsSupported) return;
    await _contactStore.mergeContacts(radioId, [
      LocalContact(
        publicKeyPrefix: p,
        name: n.isNotEmpty ? n : (_sessionRadioContacts[p] ?? p),
        type: type,
        lastHeard: DateTime.now().toUtc(),
        path: path,
        source: source,
      ),
    ]);
  }

  Future<void> _adoptPersistedContactsIntoSession() async {
    if (_sessionRadioContacts.isNotEmpty) return;
    final radioId = _connectedRadioMeshId8();
    if (radioId == null || radioId.isEmpty) return;
    if (localContactsSupported) {
      final stored = await _contactStore.loadContacts(radioId);
      if (stored.isNotEmpty) {
        final session = {
          for (final c in stored.values) c.publicKeyPrefix: c.name,
        };
        _pruneSelfContact(session);
        _sessionRadioContacts.addAll(session);
        _sessionRadioContactTypes.addAll({
          for (final c in stored.values)
            if (session.containsKey(c.publicKeyPrefix))
              c.publicKeyPrefix: c.type,
        });
        _invalidateSessionContactLookup();
        // One-time migrate legacy SharedPreferences book if present.
        final legacy = settings.contactsByRadioId[radioId];
        if (legacy != null && legacy.isNotEmpty) {
          final now = DateTime.now().toUtc();
          await _contactStore.mergeContacts(radioId, [
            for (final e in legacy.entries)
              LocalContact(
                publicKeyPrefix: e.key,
                name: e.value,
                type: 0,
                lastHeard: now,
                source: 'sync',
              ),
          ]);
        }
        notifyListeners();
        return;
      }
    }
    final persisted = settings.contactsByRadioId[radioId];
    if (persisted == null || persisted.isEmpty) return;
    final session = Map<String, String>.from(persisted);
    _pruneSelfContact(session);
    if (session.isEmpty) return;
    _sessionRadioContacts.addAll(session);
    _invalidateSessionContactLookup();
    notifyListeners();
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
      _lastSelfInfoText = extractPrintableAscii(frame);
      if (prefix.isNotEmpty) {
        _connectedRadioMeshIdPrefix = prefix;
      }
      if (publicKeyHex.length == 64) {
        _connectedRadioPublicKeyHex = publicKeyHex;
      }
      final selfInfoName = extractSelfInfoDisplayName(_lastSelfInfoText ?? '');
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
        final text = extractPrintableAscii(frame);
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

  /// Names that may be written onto scans (and therefore uploaded).
  ///
  /// Advertised names are allowed. Repeater/room contact-book names are
  /// allowed. Companion/chat and other non-infrastructure contact names are
  /// never eligible.
  Map<String, String> _namesAllowedOnScans(Map<String, String> contacts) {
    if (contacts.isEmpty) return contacts;
    final filtered = <String, String>{};
    for (final entry in contacts.entries) {
      final name = entry.value.trim();
      if (name.isEmpty) continue;
      if (_isNonInfrastructureContactName(entry.key, name)) continue;
      filtered[entry.key] = name;
    }
    return filtered;
  }

  bool _nameBelongsToContactBook(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final session = _bestContactNameForId(_sessionRadioContacts, id);
    if (session != null && session.trim() == trimmed) return true;
    for (final book in settings.contactsByRadioId.values) {
      final match = _bestContactNameForId(book, id);
      if (match != null && match.trim() == trimmed) return true;
    }
    return false;
  }

  int _backfillScanNamesFromContacts(Map<String, String> contacts) {
    final watch = Stopwatch()..start();
    meshStageStart('backfill', count: rawScans.length, n2: contacts.length);
    final storeable = _namesAllowedOnScans(contacts);
    final names = LongestHexNameIndex.fromMap(storeable);
    final sessionNames = _sessionContactNames();
    final bookNames = <LongestHexNameIndex>[
      for (final book in settings.contactsByRadioId.values)
        if (book.isNotEmpty) LongestHexNameIndex.fromMap(book),
    ];
    final types = LongestHexTypeIndex(_sessionRadioContactTypes);
    var updates = 0;
    List<RawScan>? next;
    final connectedMesh = normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
    var candidateScans = 0;
    var globalNodeContactMatches = 0;
    var globalSenderBackfillable = 0;
    var globalReceiverBackfillable = 0;

    bool nameInContactBook(String id, String name) {
      if (sessionNames.lookup(id) == name) return true;
      for (final book in bookNames) {
        if (book.lookup(id) == name) return true;
      }
      return false;
    }

    bool leakedCompanion(String id, String name) {
      if (name.isEmpty || !nameInContactBook(id, name)) return false;
      final type = types.lookup(id);
      if (type == null) return true;
      return !isInfrastructureAdvertType(type);
    }

    for (final scan in rawScans) {
      final senderId = (scan.nodeId ?? '').trim().toUpperCase();
      final observerId = (scan.observerId ?? '').trim().toUpperCase();
      final senderCurrent = (scan.senderName ?? '').trim();
      final receiverCurrent = (scan.receiverName ?? '').trim();
      final senderMatch = names.lookup(senderId);
      final observerMatch = names.lookup(observerId);
      if (senderMatch != null && senderCurrent != senderMatch) {
        globalSenderBackfillable += 1;
      }
      if (observerMatch != null && receiverCurrent != observerMatch) {
        globalReceiverBackfillable += 1;
      }
      final nodeNorm = normalizeHexId(scan.nodeId ?? '');
      if (nodeNorm.isNotEmpty && names.matchesId(nodeNorm)) {
        globalNodeContactMatches += 1;
      }
      candidateScans += 1;

      final senderLeakedCompanion = leakedCompanion(senderId, senderCurrent);
      final newSenderName = senderLeakedCompanion
          ? (senderMatch ?? _shortNodeId(senderId))
          : (senderMatch ?? scan.senderName);
      final newReceiverName = observerMatch ?? scan.receiverName;
      final senderChanged =
          (senderMatch != null && senderCurrent != senderMatch) ||
          (senderLeakedCompanion &&
              senderCurrent != (newSenderName ?? '').trim());
      final receiverChanged =
          observerMatch != null && receiverCurrent != observerMatch;
      if (!senderChanged && !receiverChanged) {
        next?.add(scan);
        continue;
      }

      updates += (senderChanged ? 1 : 0) + (receiverChanged ? 1 : 0);
      next ??= rawScans.sublist(0, candidateScans - 1).toList();
      next.add(
        normalizeRawScanIds(
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
            locallyRecorded: scan.locallyRecorded,
          ),
        ),
      );
    }
    if (updates > 0 && next != null) {
      rawScans = next;
    }
    _debugLog.debug(
      'contacts',
      'Connected-radio backfill scope: mesh=$connectedMesh '
          'candidates=$candidateScans totalScans=${rawScans.length} '
          'nodeMatches=$globalNodeContactMatches '
          'globalSenderBackfillable=$globalSenderBackfillable '
          'globalReceiverBackfillable=$globalReceiverBackfillable',
    );
    meshStageEnd(
      'backfill',
      count: rawScans.length,
      ms: watch.elapsedMilliseconds,
      n2: updates,
    );
    return updates;
  }

  void _updateConnectedRadioMeshIdFromContacts(Map<String, String> contacts) {
    final frameHex = _lastSelfInfoHex ?? '';
    if (contacts.isEmpty) return;

    final existingMesh = normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
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
    final selectedTokens = nameTokens(selectedName);

    String? inferred;
    var bestScore = -1;
    for (final entry in contacts.entries) {
      final key = normalizeHexId(entry.key);
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
    if (id.isEmpty || contacts.isEmpty) return null;
    if (identical(contacts, _sessionRadioContacts)) {
      return _sessionContactNames().lookup(id);
    }
    return LongestHexNameIndex.fromMap(contacts).lookup(id);
  }

  String? _storedAdvertisedName(String nodeId) {
    if (nodeId.trim().isEmpty) return null;
    return _advertisedNameIndex().lookup(nodeId);
  }

  /// One pass over the current history. The root build used to call this
  /// once per scan, and each call walked every row again.
  FirstAdvertisedNameIndex _advertisedNameIndex() {
    if (_advertisedNames != null &&
        identical(_advertisedNodes, nodes) &&
        identical(_advertisedResults, scanResults) &&
        identical(_advertisedRaw, rawScans)) {
      return _advertisedNames!;
    }
    final watch = Stopwatch()..start();
    final rows = nodes.length + scanResults.length + rawScans.length;
    meshStageStart('advertised_name_index', count: rows);
    final index = FirstAdvertisedNameIndex();
    for (final node in nodes) {
      index.add(node.nodeId, node.name);
    }
    for (final scan in scanResults) {
      index.add(scan.nodeId, scan.senderName);
    }
    for (final scan in rawScans) {
      index.add(scan.nodeId ?? '', scan.senderName);
    }
    _advertisedNames = index;
    _advertisedNodes = nodes;
    _advertisedResults = scanResults;
    _advertisedRaw = rawScans;
    meshStageEnd(
      'advertised_name_index',
      count: rows,
      ms: watch.elapsedMilliseconds,
    );
    return index;
  }

  void _invalidateSessionContactLookup() {
    _sessionNameIndex = null;
    _sessionNameCount = -1;
  }

  LongestHexNameIndex _sessionContactNames() {
    if (_sessionNameIndex != null &&
        _sessionNameCount == _sessionRadioContacts.length) {
      return _sessionNameIndex!;
    }
    final index = LongestHexNameIndex.fromMap(_sessionRadioContacts);
    _sessionNameIndex = index;
    _sessionNameCount = _sessionRadioContacts.length;
    return index;
  }

  String _shortNodeId(String nodeId) => shortNodeId(nodeId);

  Future<void> _cleanupWorkerDeadzoneRows(
    WorkerApi api,
    Set<String> hexes,
  ) async {
    try {
      final deleted = await api.cleanupDeadzoneRows(hexes);
      if (deleted > 0) {
        _debugLog.info(
          'sync',
          'Deleted $deleted worker deadzone row(s) for ${hexes.length} successful hex(es)',
        );
      }
    } catch (e) {
      _debugLog.warn('sync', 'Worker deadzone cleanup failed: $e');
    }
  }

  String? _connectedRadioMeshId8() {
    final mesh = normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
    if (mesh.isEmpty) return null;
    return mesh.length >= 8 ? mesh.substring(0, 8) : mesh;
  }

  Future<void> _uploadPendingScans(WorkerApi api, List<RawScan> pending) async {
    // Companion/chat contact names are stripped in [_toWorkerScanPayload].
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
      final uploadedKeys = pending.map(scanIdentity).toSet();
      rawScans = rawScans
          .map((scan) {
            if (!uploadedKeys.contains(scanIdentity(scan))) return scan;
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
    final nodeId = safePublicRadioId(scan.nodeId ?? '') ?? '';
    final nodeName = _uploadableSenderName(scan);
    final observerName = _resolveObserverNameForUpload(scan);
    final nodeEntry = <String, dynamic>{
      'nodeId': nodeId,
      if (nodeName != null && nodeName.isNotEmpty) 'name': nodeName,
      if (observerName.isNotEmpty) 'observerName': observerName,
      'rssi': scan.rssi ?? 0.0,
      'snr': scan.snr ?? 0.0,
      if (scan.snrIn != null) 'snrIn': scan.snrIn,
    };

    final radioId = (scan.radioId ?? '').trim();
    final uploadRadioId = safePublicRadioId(radioId);
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
    final senderId = scan.nodeId ?? '';
    // Keep observer self-name upload as today, but never send a companion
    // chat destination that was accidentally copied onto receiverName.
    final receiverIsSenderCompanion =
        receiver.isNotEmpty &&
        _isNonInfrastructureContactName(senderId, receiver);
    if (receiver.isNotEmpty && !receiverIsSenderCompanion) return receiver;

    final radioId = normalizeHexId(scan.radioId ?? '');
    final observerId = normalizeHexId(scan.observerId ?? '');
    final connectedName = (_connectedRadioDisplayName ?? '').trim();
    final connectedMesh = normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
    if (connectedName.isNotEmpty &&
        connectedMesh.isNotEmpty &&
        (idsLikelySameDevice(radioId, connectedMesh) ||
            idsLikelySameDevice(observerId, connectedMesh))) {
      return connectedName;
    }

    return '';
  }

  /// Scan senderName written locally and eligible for upload.
  ///
  /// Precedence: repeater/room session contact name, then a real advertised
  /// name, then the short node id. Companion/chat contact names are skipped.
  String _resolveScanSenderName({
    required String nodeId,
    required String advertisedName,
  }) {
    final infra = _infrastructureContactNameForId(nodeId);
    if (infra != null) return infra;
    final trimmed = advertisedName.trim();
    if (trimmed.isNotEmpty && !isPlaceholderNodeName(trimmed, nodeId)) {
      return trimmed;
    }
    return _shortNodeId(nodeId);
  }

  String? _uploadableSenderName(RawScan scan) {
    final name = (scan.senderName ?? '').trim();
    if (name.isEmpty) return null;
    if (_isNonInfrastructureContactName(scan.nodeId ?? '', name)) {
      return null;
    }
    return name;
  }

  String? _infrastructureContactNameForId(String id) {
    if (!_isInfrastructureContactId(id)) return null;
    final name = _bestContactNameForId(_sessionRadioContacts, id);
    if (name == null || name.isEmpty) return null;
    if (isPlaceholderNodeName(name, id)) return null;
    return name;
  }

  bool _isInfrastructureContactId(String id) {
    final type = _bestContactTypeForId(id);
    if (type == null) return false;
    return isInfrastructureAdvertType(type);
  }

  bool _isNonInfrastructureContactName(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    if (!_nameBelongsToContactBook(id, trimmed)) return false;
    return !_isInfrastructureContactId(id);
  }

  int? _bestContactTypeForId(String id) {
    if (id.isEmpty || _sessionRadioContactTypes.isEmpty) return null;
    return LongestHexTypeIndex(_sessionRadioContactTypes).lookup(id);
  }

  String _selectedBleDeviceName() {
    final selectedId = bleSelectedDeviceId;
    if (selectedId == null || selectedId.isEmpty) return '';
    final fromMap = _bleDeviceNamesById[selectedId];
    if (fromMap != null &&
        fromMap.isNotEmpty &&
        !_isPlaceholderBleDeviceName(fromMap)) {
      return fromMap;
    }
    for (final label in bleScanDevices) {
      final labelId = _extractDeviceIdFromBleLabel(label);
      if (labelId == selectedId) {
        final name = _extractDeviceNameFromBleLabel(label);
        if (!_isPlaceholderBleDeviceName(name)) {
          return name;
        }
        break;
      }
    }
    return '';
  }

  void _pruneSelfContact(Map<String, String> contacts) {
    if (contacts.isEmpty) return;
    final mesh = normalizeHexId(_connectedRadioMeshIdPrefix ?? '');
    if (mesh.isNotEmpty && contacts.remove(mesh) != null) {
      _debugLog.info('contacts', 'Removed self contact entry for mesh=$mesh');
      return;
    }

    final selectedTokens = nameTokens(_selectedBleDeviceName().toLowerCase());
    if (selectedTokens.isEmpty) return;
    String? bestKey;
    var bestScore = 0;
    for (final entry in contacts.entries) {
      final entryTokens = nameTokens(entry.value.toLowerCase());
      if (entryTokens.isEmpty) continue;
      var score = 0;
      for (final token in selectedTokens) {
        if (token.length >= 4 && entryTokens.contains(token)) {
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
      _scanLoopWanted = false;
      _resumeAutoScanAfterReconnect = false;
      _cancelScanLoopReconnect('scan loop paused');
      bleScanStatus = 'idle';
      _bleAutoScanTimer?.cancel();
      _resetAutoScanSchedule();
      _smartScanPausedForRecentCoverage = false;
      _smartScanPausedZoneId = null;
      _syncAndroidScanForeground();
      notifyListeners();
      return;
    }

    if (!bleConnected) {
      await connectBle();
      if (!bleConnected) return;
    }

    bleScanning = true;
    _scanLoopWanted = true;
    _scanReconnectAttempt = 0;
    _manualBleDisconnectRequested = false;
    _cancelScanLoopReconnect('scan loop started');
    _debugLog.info('ble_scan', 'Auto scan started');
    bleScanStatus = 'idle';
    notifyListeners();
    _startAutoScanLoop();
    unawaited(_maybePromptBatteryOptimization());
    await _runAutoScanCycle();
    if (!bleScanning || !bleConnected || !_transport.isConnected) {
      _debugLog.warn(
        'ble_scan',
        'Auto scan loop not started because BLE is no longer connected',
      );
      _bleAutoScanTimer?.cancel();
      if (_scanLoopWanted &&
          !_manualBleDisconnectRequested &&
          !bleConnected &&
          !kIsWeb) {
        _armScanLoopReconnect(reason: 'scan loop lost the radio');
      } else {
        _syncAndroidScanForeground();
      }
      return;
    }
  }

  Future<void> forceBleScan() async {
    if (!await _ensureBleAvailable(context: 'ble_discover')) {
      return;
    }
    if (bleScanning) {
      final forcedAt = DateTime.now();
      _scheduleNextAutoScanFrom(forcedAt);
      _autoScanDueWhileBusy = false;
      _debugLog.info(
        'smart_scan',
        'Force scan requested; reset auto-loop timer '
            'interval=${settings.scanIntervalSeconds}s',
      );
      notifyListeners();
    }
    await runNodeDiscover();
  }

  void _cancelScanLoopReconnect(String reason) {
    final pending = _scanReconnectTimer != null || _scanReconnectAttemptActive;
    _scanReconnectGeneration++;
    _scanReconnectTimer?.cancel();
    _scanReconnectTimer = null;
    if (pending) {
      _debugLog.info('ble', 'Scan loop reconnect cancelled: $reason');
    }
  }

  void _abandonScanLoopReconnect(String reason) {
    _debugLog.warn('ble', 'Scan loop reconnect abandoned: $reason');
    _scanLoopWanted = false;
    _resumeAutoScanAfterReconnect = false;
    _cancelScanLoopReconnect(reason);
    _syncAndroidScanForeground();
  }

  /// Schedule the next background reconnect while the scan loop is wanted.
  ///
  /// Overlapping calls are ignored. A failed attempt does not clear
  /// [_scanLoopWanted]. The timer is cancelled on pause, manual disconnect,
  /// and dispose.
  void _armScanLoopReconnect({String? reason}) {
    if (kIsWeb) return;
    if (!_scanLoopWanted || _manualBleDisconnectRequested) return;
    if (_scanReconnectTimer != null || _scanReconnectAttemptActive) {
      _debugLog.debug(
        'ble',
        'Scan loop reconnect already pending; not starting another '
            'reason=${reason ?? 'unspecified'}',
      );
      return;
    }
    final deviceId = (bleSelectedDeviceId ?? '').trim();
    if (deviceId.isEmpty) {
      _abandonScanLoopReconnect('no selected radio');
      return;
    }
    final delay = scanReconnectBackoffDelay(_scanReconnectAttempt);
    final generation = _scanReconnectGeneration;
    _debugLog.info(
      'ble',
      'Scan loop reconnect in ${delay.inSeconds}s '
          'attempt=${_scanReconnectAttempt + 1} '
          'reason=${reason ?? 'link dropped'}',
    );
    _scanReconnectTimer = Timer(delay, () {
      _scanReconnectTimer = null;
      unawaited(_runScanLoopReconnectAttempt(generation));
    });
    _syncAndroidScanForeground();
  }

  Future<void> _runScanLoopReconnectAttempt(int generation) async {
    if (generation != _scanReconnectGeneration) return;
    if (!_scanLoopWanted || _manualBleDisconnectRequested) return;
    if (_scanReconnectAttemptActive) return;
    if (bleConnected && _transport.isConnected) {
      _scanReconnectAttempt = 0;
      if (!(bleScanning && (_bleAutoScanTimer?.isActive ?? false))) {
        await _resumeScanLoopAfterReconnect();
      } else {
        _syncAndroidScanForeground();
      }
      return;
    }
    _scanReconnectAttemptActive = true;
    final attemptNumber = _scanReconnectAttempt + 1;
    _debugLog.info(
      'ble',
      'Scan loop reconnect attempt $attemptNumber starting',
    );
    var failed = true;
    try {
      _silentBleConnectDepth++;
      final ok = await connectBle(interactive: false);
      failed = !ok || !bleConnected || !_transport.isConnected;
    } catch (e) {
      _debugLog.warn(
        'ble',
        'Scan loop reconnect attempt $attemptNumber error: $e',
      );
      failed = true;
    } finally {
      if (_silentBleConnectDepth > 0) {
        _silentBleConnectDepth--;
      }
      _scanReconnectAttemptActive = false;
    }
    if (generation != _scanReconnectGeneration ||
        _manualBleDisconnectRequested ||
        !_scanLoopWanted) {
      _debugLog.info(
        'ble',
        'Scan loop reconnect finished after the loop was stopped',
      );
      if (_manualBleDisconnectRequested &&
          bleConnected &&
          _transport.isConnected) {
        await disconnectBle();
      }
      return;
    }
    if (!failed) {
      _debugLog.info('ble', 'Scan loop reconnect succeeded');
      _scanReconnectAttempt = 0;
      await _resumeScanLoopAfterReconnect();
      return;
    }
    _scanReconnectAttempt++;
    _debugLog.warn(
      'ble',
      'Scan loop reconnect attempt $attemptNumber failed; loop still wanted',
    );
    _armScanLoopReconnect(reason: 'previous attempt failed');
  }

  Future<void> _resumeScanLoopAfterReconnect() async {
    if (_manualBleDisconnectRequested) return;
    if (!_scanLoopWanted && !_resumeAutoScanAfterReconnect) return;
    _resumeAutoScanAfterReconnect = false;
    _scanLoopWanted = true;
    bleScanning = true;
    bleScanStatus = 'idle';
    notifyListeners();
    _startAutoScanLoop();
    await _runAutoScanCycle();
    if (!bleScanning || !bleConnected || !_transport.isConnected) {
      _bleAutoScanTimer?.cancel();
      if (_scanLoopWanted &&
          !_manualBleDisconnectRequested &&
          !bleConnected &&
          !kIsWeb) {
        _armScanLoopReconnect(reason: 'link lost while resuming the scan loop');
      } else {
        _syncAndroidScanForeground();
      }
    }
  }

  Future<void> _maybePromptBatteryOptimization() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (_batteryOptimizationPromptAsked == true) return;
    if (_batteryOptPromptInFlight) return;
    final prompt = onBatteryOptimizationPrompt;
    if (prompt == null) return;
    _batteryOptPromptInFlight = true;
    try {
      final asked = await _settingsStore.batteryOptimizationPromptAsked();
      if (asked) {
        _batteryOptimizationPromptAsked = true;
        return;
      }
      final ignoring = await isIgnoringBatteryOptimizations();
      if (ignoring || !_scanLoopWanted) return;
      final shown = await prompt();
      if (!shown) return;
      await _settingsStore.markBatteryOptimizationPromptAsked();
      _batteryOptimizationPromptAsked = true;
      _debugLog.info(
        'ble_scan',
        'Battery optimization prompt shown once for the scan loop',
      );
    } catch (e) {
      _debugLog.warn('ble_scan', 'Battery optimization prompt failed: $e');
    } finally {
      _batteryOptPromptInFlight = false;
    }
  }

  Future<void> _attemptAutoReconnect({String? reason}) async {
    if (kIsWeb) return;
    if (_scanLoopWanted) return;
    if (_autoReconnectInProgress || _manualBleDisconnectRequested) return;
    if (!settings.bleAutoConnect) return;
    if (bleSelectedDeviceId == null || bleSelectedDeviceId!.isEmpty) return;
    _autoReconnectInProgress = true;
    try {
      _debugLog.info(
        'ble',
        'Attempting auto-reconnect after disconnect'
            '${reason == null || reason.isEmpty ? '' : ' ($reason)'}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (_scanLoopWanted || _manualBleDisconnectRequested) return;
      await connectBle();
      if (!bleConnected || !_transport.isConnected) {
        _debugLog.warn('ble', 'Auto-reconnect failed');
        return;
      }
      if (_resumeAutoScanAfterReconnect || _scanLoopWanted) {
        await _resumeScanLoopAfterReconnect();
      }
    } finally {
      _autoReconnectInProgress = false;
    }
  }

  int _secondsUntilNextAutoScan(DateTime now) {
    final dueAt = _nextAutoScanDueAt;
    if (dueAt == null) return 0;
    return _secondsUntilDue(dueAt, now);
  }

  /// Whole seconds until [dueAt], matching the 1s tick.
  ///
  /// [DateTime.difference.inMilliseconds] truncates, so a due that is still
  /// a fraction of a millisecond ahead already counts as reached.
  int _secondsUntilDue(DateTime dueAt, DateTime now) {
    final remainingMs = dueAt.difference(now).inMilliseconds;
    if (remainingMs <= 0) return 0;
    return (remainingMs + 999) ~/ 1000;
  }

  void _resetAutoScanSchedule({bool clearCountdown = true}) {
    _autoScanRemainingSeconds = 0;
    _autoScanDueWhileBusy = false;
    _autoScanTickInProgress = false;
    _lastAutoScanTriggerAt = null;
    _nextAutoScanDueAt = null;
    if (clearCountdown) {
      bleNextScanCountdown = null;
    }
  }

  void _scheduleNextAutoScanFrom(DateTime triggerAt) {
    _lastAutoScanTriggerAt = triggerAt;
    _nextAutoScanDueAt = triggerAt.add(
      Duration(seconds: settings.scanIntervalSeconds),
    );
    _autoScanRemainingSeconds = settings.scanIntervalSeconds;
    bleNextScanCountdown = _autoScanRemainingSeconds;
  }

  /// Schedule the next due from the due that started this cycle.
  ///
  /// When the 1s tick already counts that due as reached (late, or still a
  /// fraction of a millisecond ahead), that due is the anchor. Later dues
  /// stay on T, T+interval, T+2*interval. Anchoring on [DateTime.now] would
  /// fold the tick's offset into the next interval. A due that is still at
  /// least a millisecond away is the immediate cycle after start; that pass
  /// uses [DateTime.now] so the pre-set future due does not add a second
  /// interval.
  void _scheduleAutoScanCycleFromDue() {
    final now = DateTime.now();
    final dueAt = _nextAutoScanDueAt;
    final triggerAt = (dueAt != null && _secondsUntilDue(dueAt, now) == 0)
        ? dueAt
        : now;
    _scheduleNextAutoScanFrom(triggerAt);
  }

  /// Display-only countdown started as discovery is sent.
  ///
  /// Writes [bleNextScanCountdown] and notifies. It does not schedule the
  /// next auto scan, touch the tick lock, or start or stop a cycle. The auto
  /// loop reads the due time the cycle already set. A manual scan counts down
  /// [discoverWait] from this moment.
  void _beginCountdownAtDiscoverSend({
    required bool autoLoopOwnsCountdown,
    required Duration discoverWait,
  }) {
    _bleCountdownTimer?.cancel();
    if (autoLoopOwnsCountdown) {
      bleNextScanCountdown = _secondsUntilNextAutoScan(DateTime.now());
      _bleCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!identical(_bleCountdownTimer, timer)) {
          timer.cancel();
          return;
        }
        bleNextScanCountdown = _secondsUntilNextAutoScan(DateTime.now());
        notifyListeners();
      });
    } else {
      bleNextScanCountdown = discoverWait.inSeconds;
      _bleCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!identical(_bleCountdownTimer, timer)) {
          timer.cancel();
          return;
        }
        final current = bleNextScanCountdown ?? 0;
        if (current <= 1) {
          bleNextScanCountdown = 0;
          timer.cancel();
          if (identical(_bleCountdownTimer, timer)) {
            _bleCountdownTimer = null;
          }
        } else {
          bleNextScanCountdown = current - 1;
        }
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> _sendNodeDiscoverCommand() {
    final override = debugDiscoverSend;
    if (override != null) return override();
    return _bleProtocol.run(_protocol.nodeDiscover());
  }

  void _startAutoScanLoop() {
    _bleAutoScanTimer?.cancel();
    _autoScanTickInProgress = false;
    _debugLog.debug(
      'ble_scan',
      'Auto scan loop interval=${settings.scanIntervalSeconds}s',
    );
    _nextAutoScanDueAt ??= DateTime.now().add(
      Duration(seconds: settings.scanIntervalSeconds),
    );
    _autoScanRemainingSeconds = _secondsUntilNextAutoScan(DateTime.now());
    _autoScanDueWhileBusy = false;
    bleNextScanCountdown = _autoScanRemainingSeconds;

    _bleAutoScanTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (_autoScanTickInProgress) return;
      _autoScanTickInProgress = true;
      try {
        if (!bleScanning) {
          timer.cancel();
          _syncAndroidScanForeground();
          return;
        }
        if (_smartScanPausedForRecentCoverage) {
          final now = DateTime.now();
          bleNextScanCountdown = null;
          if (_lastSmartScanPauseLogAt == null ||
              now.difference(_lastSmartScanPauseLogAt!) >=
                  const Duration(seconds: 20)) {
            _lastSmartScanPauseLogAt = now;
            _debugLog.debug(
              'smart_scan',
              'Pause active zone=${_smartScanPausedZoneId ?? 'unknown'} '
                  'reason=recent_coverage waiting_for=zone_change',
            );
          }
          notifyListeners();
          return;
        }
        final now = DateTime.now();
        final remainingSeconds = _secondsUntilNextAutoScan(now);
        _autoScanRemainingSeconds = remainingSeconds;
        if (bleBusy) {
          if (remainingSeconds <= 0) {
            _autoScanRemainingSeconds = 0;
            bleNextScanCountdown = 0;
            if (!_autoScanDueWhileBusy) {
              _autoScanDueWhileBusy = true;
              _debugLog.info(
                'smart_scan',
                'Auto loop became due while discover is busy; '
                    'next cycle will start immediately after current discover',
              );
            }
          } else {
            bleNextScanCountdown = remainingSeconds;
          }
          notifyListeners();
          return;
        }
        if (_autoScanDueWhileBusy) {
          _autoScanDueWhileBusy = false;
          bleNextScanCountdown = 0;
          notifyListeners();
          _debugLog.info(
            'smart_scan',
            'Discover finished after due time; launching immediate next cycle',
          );
          await _runAutoScanCycle();
          return;
        }
        if (remainingSeconds <= 0) {
          bleNextScanCountdown = 0;
          notifyListeners();
          if (!bleBusy) {
            _debugLog.info(
              'smart_scan',
              'Auto loop trigger countdown reached 0; starting cycle '
                  'interval=${settings.scanIntervalSeconds}s',
            );
            await _runAutoScanCycle();
          }
          return;
        }
        bleNextScanCountdown = remainingSeconds;
        notifyListeners();
      } finally {
        _autoScanTickInProgress = false;
      }
    });
    // After this synchronous turn, so the due time is scheduled before the
    // foreground sync and the one-second timer stays aligned with it.
    scheduleMicrotask(_syncAndroidScanForeground);
  }

  /// Keep Android's scan foreground service aligned with the loop.
  ///
  /// The service stays up while the loop is running, and while the user still
  /// wants it during a reconnect. It drops when the user pauses, disconnects,
  /// or reconnect is abandoned. Web, Linux, and iOS never enter this path.
  void _syncAndroidScanForeground() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final scanLoopRunning =
        bleScanning && (_bleAutoScanTimer?.isActive ?? false);
    final bleLinkUp = bleConnected && _transport.isConnected;
    final loopWanted = _scanLoopWanted && !_manualBleDisconnectRequested;
    unawaited(
      _locationService.syncScanLoopForeground(
        scanLoopRunning: scanLoopRunning,
        bleConnected: bleLinkUp,
        loopWanted: loopWanted,
      ),
    );
  }

  Future<void> _runAutoScanCycle() async {
    if (bleBusy) {
      _debugLog.debug(
        'smart_scan',
        'Cycle request ignored: discover already busy',
      );
      return;
    }
    final cycleStartedAt = DateTime.now();
    final cycleId = ++_autoScanCycleSeq;
    final sinceLastTriggerMs = _lastAutoScanTriggerAt == null
        ? null
        : cycleStartedAt.difference(_lastAutoScanTriggerAt!).inMilliseconds;
    final expectedTriggerAt = _lastAutoScanTriggerAt?.add(
      Duration(seconds: settings.scanIntervalSeconds),
    );
    final triggerDriftMs = expectedTriggerAt == null
        ? null
        : cycleStartedAt.difference(expectedTriggerAt).inMilliseconds;
    final currentZone = (deviceLatitude != null && deviceLongitude != null)
        ? hexKey(deviceLatitude!, deviceLongitude!)
        : null;
    _debugLog.info(
      'smart_scan',
      'Cycle#$cycleId start zone=${currentZone ?? 'unknown'} '
          'sinceLastTriggerMs=${sinceLastTriggerMs ?? 'first'} '
          'triggerDriftMs=${triggerDriftMs ?? 'n/a'} '
          'countdown=${bleNextScanCountdown ?? -1}',
    );
    final smartScanActive =
        settings.smartScanEnabled && settings.smartScanDays >= 1;
    if (!smartScanActive) {
      _smartScanPausedForRecentCoverage = false;
      _smartScanPausedZoneId = null;
      _lastSmartScanPauseLogAt = null;
      _scheduleAutoScanCycleFromDue();
      _debugLog.info(
        'ble_scan',
        'Cycle#$cycleId smart-scan disabled; running discovery',
      );
      final discoverStartedAt = DateTime.now();
      await runNodeDiscover();
      _debugLog.info(
        'ble_scan',
        'Cycle#$cycleId finished discoverMs='
            '${DateTime.now().difference(discoverStartedAt).inMilliseconds} '
            'responses=${bleDiscoveries.length} status=$bleScanStatus',
      );
      return;
    }
    final decisionStartedAt = DateTime.now();
    final decision = _evaluateSmartScanDecision();
    final decisionMs = DateTime.now()
        .difference(decisionStartedAt)
        .inMilliseconds;
    if (decision.skip) {
      _smartScanPausedForRecentCoverage = true;
      _smartScanPausedZoneId = decision.zoneId;
      bleScanStatus = 'done';
      bleStatus = 'Smart scan skipped: recently covered';
      bleLastDiscoverError = null;
      _lastSmartScanSkipAt = DateTime.now();
      _nextAutoScanDueAt = null;
      _autoScanRemainingSeconds = 0;
      bleNextScanCountdown = null;
      _debugLog.info(
        'smart_scan',
        'Cycle#$cycleId skipped zone=${decision.zoneId ?? 'unknown'} '
            'reason=${decision.reason} decisionMs=$decisionMs '
            'nextScan=on_zone_change',
      );
      notifyListeners();
      return;
    }
    _smartScanPausedForRecentCoverage = false;
    _smartScanPausedZoneId = decision.zoneId;
    _lastSmartScanPauseLogAt = null;
    _scheduleAutoScanCycleFromDue();
    final sinceSkipMs = _lastSmartScanSkipAt == null
        ? null
        : cycleStartedAt.difference(_lastSmartScanSkipAt!).inMilliseconds;
    _debugLog.info(
      'smart_scan',
      'Cycle#$cycleId proceeding zone=${decision.zoneId ?? 'unknown'} '
          'reason=${decision.reason} decisionMs=$decisionMs '
          'sinceLastSkipMs=${sinceSkipMs ?? 'none'}',
    );
    final discoverStartedAt = DateTime.now();
    await runNodeDiscover();
    _debugLog.info(
      'smart_scan',
      'Cycle#$cycleId finished discoverMs='
          '${DateTime.now().difference(discoverStartedAt).inMilliseconds} '
          'responses=${bleDiscoveries.length} status=$bleScanStatus',
    );
  }

  Future<void> _onObserverZoneMaybeChanged() async {
    if (!bleScanning || !bleConnected || bleBusy) return;
    if (!settings.smartScanEnabled || settings.smartScanDays < 1) {
      if (_smartScanPausedForRecentCoverage || _smartScanPausedZoneId != null) {
        _smartScanPausedForRecentCoverage = false;
        _smartScanPausedZoneId = null;
        _lastSmartScanPauseLogAt = null;
        notifyListeners();
      }
      return;
    }
    if (!_smartScanPausedForRecentCoverage) return;

    final decision = _evaluateSmartScanDecision();
    if (decision.skip) {
      if (decision.zoneId != _smartScanPausedZoneId) {
        _debugLog.info(
          'smart_scan',
          'Observer moved but still in recent-coverage zone='
              '${decision.zoneId ?? 'unknown'} reason=${decision.reason}',
        );
      }
      _smartScanPausedZoneId = decision.zoneId;
      return;
    }

    final fromZone = _smartScanPausedZoneId;
    _smartScanPausedForRecentCoverage = false;
    _smartScanPausedZoneId = decision.zoneId;
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
      if (isDeadLikeScan(scan)) continue;
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

  Future<void> _rebuildDerivedData({bool skipZones = false}) async {
    final generation = ++_derivedGeneration;
    final scans = rawScans;
    final derivedWatch = Stopwatch()..start();
    meshStageStart('derived', count: scans.length, n2: skipZones ? 0 : 1);
    final derived = await runOffUi(
      buildDerivedScanDataWorker,
      <String, Object?>{'scans': scans, 'includeZones': !skipZones},
      weight: scans.length,
    );
    meshStageEnd(
      'derived',
      count: scans.length,
      ms: derivedWatch.elapsedMilliseconds,
      n2: derived.zones.length,
    );
    if (generation != _derivedGeneration) return;
    if (!skipZones) {
      coverageZones = derived.zones;
    }
    nodes = derived.nodes;
    scanResults = derived.scanResults;
  }

  void markHostDetaching() {
    _hostDetaching = true;
    _debugLog.info(
      'app_state',
      'Host detaching; will skip explicit transport disconnect on dispose',
    );
  }

  @override
  void dispose() {
    _debugLog.info('app_state', 'Disposing app state');
    _scanLoopWanted = false;
    _cancelScanLoopReconnect('dispose');
    _syncService.dispose();
    _locationService.dispose();
    _bleAvailabilitySubscription?.cancel();
    _bleAutoScanTimer?.cancel();
    _bleCountdownTimer?.cancel();
    _stopPassiveAdvertListener();
    final skipTransportDisposeOnMobileDetach =
        _hostDetaching &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (skipTransportDisposeOnMobileDetach) {
      _debugLog.info(
        'app_state',
        'Skipped explicit transport dispose on mobile detach',
      );
    } else {
      unawaited(_transport.dispose());
    }
    super.dispose();
  }

  void _configurePeriodicSyncTimer() {
    _syncService.isReadyToSync = () => !loading;
    _syncService.onPeriodicSyncDue = syncFromWorker;
    _syncService.configure(
      intervalMinutes: _resolvedPeriodicSyncIntervalMinutes(),
      forceOffline: settings.forceOffline,
    );
  }

  int _resolvedPeriodicSyncIntervalMinutes([int? configured]) {
    final value = configured ?? settings.uploadBatchIntervalMinutes;
    if (value < 30) return 30;
    if (value > 1440) return 1440;
    return value;
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
        staticDataBaseUrl: AppConfig.staticDataUrl,
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
            (scan) => (safePublicRadioId(scan.radioId ?? '') ?? '') != radioId,
          )
          .toList(growable: false);
      final removedLocal = rawScans.length - next.length;
      rawScans = next;
      await _rebuildDerivedData();
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
    final signatureHex = bytesToHex(signature);
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
