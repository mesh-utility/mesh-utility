import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/transport/linux_ble_pairing_service_base.dart';
import 'package:mesh_utility/transport/protocol.dart';
import 'package:mesh_utility/transport/transport_core.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:mesh_utility/transport/linux_ble_pairing_service_stub.dart'
    if (dart.library.io) 'package:mesh_utility/transport/linux_ble_pairing_service.dart'
    as linux_pair;

class BleTransport extends Transport {
  static const String _nusServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String _nusWriteUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const String _nusNotifyUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  static final String _meshCoreServiceUuidCanonical =
      BleUuidParser.stringOrNull(_nusServiceUuid) ?? _nusServiceUuid;

  BleTransport({
    this.preferredDeviceId,
    this.namePrefixes = const [],
    this.scanTimeout = const Duration(seconds: 12),
    this.connectionTimeout = const Duration(seconds: 20),
  }) : super('ble');

  String? preferredDeviceId;
  final List<String> namePrefixes;
  final Duration scanTimeout;
  final Duration connectionTimeout;
  void Function(String deviceId, String deviceName)? onScanResult;
  Future<String?> Function(String deviceId)? onRequestPin;
  void Function({required bool connected, String? deviceId, String? reason})?
  onConnectionStateChanged;
  final LinuxBlePairingServiceBase _linuxPairingService = linux_pair
      .createLinuxBlePairingService();
  final AppDebugLogService _debugLog = AppDebugLogService.instance;

  final _inboundController = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _valueSubscription;
  StreamSubscription<BleDevice>? _scanSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  bool _scanInProgress = false;
  bool _manualDisconnectInProgress = false;
  bool _unexpectedResetInProgress = false;

  String? _deviceId;
  String? _serviceUuid;
  String? _writeCharacteristicUuid;
  String? _notifyCharacteristicUuid;
  bool _writeWithoutResponse = false;
  bool _connected = false;
  final List<int> _rxAssembleBuffer = <int>[];
  int? _rxAssembleCode;
  int? _rxAssembleExpectedLength;
  bool _contactStripChunkHeader = false;

  String? get deviceId => _deviceId;
  String? get boundServiceUuid => _serviceUuid;

  Future<AvailabilityState> getAvailabilityState() {
    return UniversalBle.getBluetoothAvailabilityState();
  }

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get inbound => _inboundController.stream;

  @override
  Future<void> connect() async {
    _debugLog.info('ble_transport', 'Requesting BLE permissions');
    await UniversalBle.requestPermissions(withAndroidFineLocation: !kIsWeb);

    final state = await UniversalBle.getBluetoothAvailabilityState();
    if (state != AvailabilityState.poweredOn) {
      _debugLog.error('ble_transport', 'Bluetooth not powered on: $state');
      throw StateError('Bluetooth is not powered on: $state');
    }

    final targetDeviceId = preferredDeviceId;
    if (targetDeviceId == null || targetDeviceId.isEmpty) {
      throw StateError('No BLE device selected');
    }
    await _prepareFreshLink(targetDeviceId);
    _debugLog.info('ble_transport', 'Target device selected: $targetDeviceId');
    await _ensureLinuxPairing(targetDeviceId);
    try {
      await _connectAndBindWithSoftRetry(targetDeviceId);
    } catch (e) {
      if (!_isLinuxDesktop) rethrow;
      _debugLog.warn(
        'linux_ble_pairing',
        'Connect failed for $targetDeviceId; removing bond and retrying pairing once: $e',
      );
      await _linuxPairingService.removeDevice(
        targetDeviceId,
        onLog: (message) => _debugLog.info('linux_ble_pairing', message),
      );
      await _ensureLinuxPairing(targetDeviceId);
      await _connectAndBindWithSoftRetry(targetDeviceId);
    }
  }

  Future<void> _prepareFreshLink(String targetDeviceId) async {
    // Ensure scan and any stale connection state from a previous app session
    // are cleared before a fresh connect attempt.
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _scanInProgress = false;

    if (!kIsWeb) {
      try {
        await UniversalBle.disconnect(targetDeviceId);
        _debugLog.debug(
          'ble_transport',
          'Pre-connect stale link reset attempted for $targetDeviceId',
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } catch (_) {
        // Not connected is expected on many runs.
      }
    }

    await _valueSubscription?.cancel();
    _valueSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _resetSessionState();
  }

  bool get _isLinuxDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  Duration get _effectiveConnectTimeout {
    if (!_isLinuxDesktop) return connectionTimeout;
    // BlueZ may need extra time immediately after trust/pairing operations.
    const linuxMin = Duration(seconds: 35);
    return connectionTimeout > linuxMin ? connectionTimeout : linuxMin;
  }

  Future<void> _connectAndBindWithSoftRetry(String targetDeviceId) async {
    try {
      await _connectAndBind(targetDeviceId);
      return;
    } catch (e) {
      if (!_isLinuxDesktop && !kIsWeb) rethrow;
      if (kIsWeb) {
        _debugLog.warn(
          'ble_transport',
          'Initial web connect/bind attempt failed for $targetDeviceId: $e; retrying once',
        );
        await _prepareFreshLink(targetDeviceId);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await _connectAndBind(targetDeviceId);
        return;
      }
      _debugLog.warn(
        'ble_transport',
        'Initial Linux connect attempt failed for $targetDeviceId: $e; retrying once',
      );
      try {
        await UniversalBle.disconnect(targetDeviceId);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _connectAndBind(targetDeviceId);
    }
  }

  Future<void> _ensureLinuxPairing(String deviceId) async {
    if (!_isLinuxDesktop) return;

    if (await _linuxPairingService.isPairedAndTrusted(deviceId)) {
      _debugLog.info(
        'linux_ble_pairing',
        'Device $deviceId already paired/trusted',
      );
      return;
    }

    _debugLog.info(
      'linux_ble_pairing',
      'Device $deviceId is not paired/trusted; starting bluetoothctl pairing flow',
    );
    final paired = await _linuxPairingService.pairAndTrust(
      remoteId: deviceId,
      onLog: (message) => _debugLog.info('linux_ble_pairing', message),
      onRequestPin: () async {
        _debugLog.info(
          'linux_ble_pairing',
          'Pairing challenge requesting PIN/passkey for $deviceId',
        );
        return onRequestPin?.call(deviceId);
      },
    );
    if (!paired) {
      _debugLog.error('linux_ble_pairing', 'Pair/trust failed for $deviceId');
      throw StateError('BLE pairing failed for $deviceId');
    }
    _debugLog.info('linux_ble_pairing', 'Pair/trust succeeded for $deviceId');
  }

  Future<void> _connectAndBind(String targetDeviceId) async {
    // Ensure scanner is not left running from a previous discovery pass.
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    final timeout = _effectiveConnectTimeout;
    _debugLog.info(
      'ble_transport',
      'Connecting to $targetDeviceId timeout=${timeout.inSeconds}s',
    );
    await UniversalBle.connect(targetDeviceId, timeout: timeout);
    _debugLog.info('ble_transport', 'Connected to device $targetDeviceId');
    _deviceId = targetDeviceId;
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      try {
        final mtu = await UniversalBle.requestMtu(targetDeviceId, 247);
        _debugLog.info(
          'ble_transport',
          'Requested MTU=247 (${defaultTargetPlatform.name}), negotiated=$mtu',
        );
      } catch (e) {
        _debugLog.warn('ble_transport', 'MTU request failed/ignored: $e');
      }
    }

    try {
      final services = await UniversalBle.discoverServices(targetDeviceId);
      _bindCharacteristics(services);
    } catch (e) {
      final message = e.toString().toLowerCase();
      if (kIsWeb && message.contains('blocklisted uuid')) {
        _debugLog.warn(
          'ble_transport',
          'Web service discovery blocked by browser UUID policy; using known NUS characteristics',
        );
        _bindKnownNusCharacteristics();
      } else {
        rethrow;
      }
    }
    await _subscribeInbound();
    _connected = true;
    await _connectionSubscription?.cancel();
    _connectionSubscription = UniversalBle.connectionStream(targetDeviceId)
        .listen((connected) {
          if (connected) return;
          unawaited(_handleUnexpectedDisconnect('connection state changed'));
        });
    onConnectionStateChanged?.call(
      connected: true,
      deviceId: _deviceId,
      reason: 'connected',
    );
    _debugLog.info(
      'ble_transport',
      'Ready: service=$_serviceUuid write=$_writeCharacteristicUuid notify=$_notifyCharacteristicUuid',
    );
  }

  @override
  Future<void> disconnect() async {
    _debugLog.info('ble_transport', 'Disconnect requested');
    _manualDisconnectInProgress = true;
    final currentDeviceId = _deviceId;
    try {
      if (currentDeviceId != null) {
        try {
          if (_serviceUuid != null && _notifyCharacteristicUuid != null) {
            await UniversalBle.unsubscribe(
              currentDeviceId,
              _serviceUuid!,
              _notifyCharacteristicUuid!,
            );
          }
        } catch (_) {}

        try {
          await UniversalBle.disconnect(currentDeviceId);
        } catch (_) {}
      }

      await _valueSubscription?.cancel();
      _valueSubscription = null;
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;

      _resetSessionState();
      onConnectionStateChanged?.call(
        connected: false,
        deviceId: currentDeviceId,
        reason: 'manual disconnect',
      );
      _debugLog.info('ble_transport', 'Disconnected and cleared BLE session');
    } finally {
      _manualDisconnectInProgress = false;
    }
  }

  @override
  Future<void> send(Uint8List payload) async {
    final currentDeviceId = _deviceId;
    final serviceUuid = _serviceUuid;
    final writeCharacteristicUuid = _writeCharacteristicUuid;

    if (!_connected ||
        currentDeviceId == null ||
        serviceUuid == null ||
        writeCharacteristicUuid == null) {
      _debugLog.error('ble_transport', 'send() while disconnected');
      throw StateError('BLE transport is not connected');
    }

    _debugLog.debug('ble_transport_tx', 'Sending ${payload.length} byte(s)');
    await UniversalBle.write(
      currentDeviceId,
      serviceUuid,
      writeCharacteristicUuid,
      payload,
      withoutResponse: _writeWithoutResponse,
    );
  }

  Future<void> scanDevices({Duration? timeout}) async {
    if (_scanInProgress) {
      _debugLog.warn(
        'ble_scan',
        'Scan request ignored: scan already in progress',
      );
      return;
    }
    _scanInProgress = true;
    final scanFor = timeout ?? scanTimeout;
    _debugLog.info(
      'ble_scan',
      'Scanning devices timeout=${scanFor.inSeconds}s '
          'service=$_meshCoreServiceUuidCanonical',
    );
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    await _scanSubscription?.cancel();
    _scanSubscription = null;

    final seenSession = <String>{};
    final seenMeshcoreIds = <String>{};
    int handleDevice(BleDevice device) {
      if (!_hasMeshCoreService(device)) {
        final key = '${device.deviceId}|ignored-no-meshcore-service';
        if (!seenSession.add(key)) return 0;
        _debugLog.debug(
          'ble_scan',
          'Ignoring non-meshcore advertisement id=${device.deviceId} '
              'name=${(device.name ?? device.rawName ?? '').trim()} '
              'services=${device.services}',
        );
        return 0;
      }
      final seenName = (device.name ?? device.rawName ?? '').trim();
      onScanResult?.call(device.deviceId, seenName);
      final key = '${device.deviceId}|$seenName';
      if (seenSession.add(key)) {
        _debugLog.debug(
          'ble_scan',
          'Seen meshcore device id=${device.deviceId} name=$seenName',
        );
      }
      return seenMeshcoreIds.add(device.deviceId) ? 1 : 0;
    }

    Future<int> runScanPass({
      required ScanFilter filter,
      required Duration duration,
      required String label,
    }) async {
      if (duration.inMilliseconds <= 0) return 0;
      var passHits = 0;
      _debugLog.debug(
        'ble_scan',
        'Starting $label scan pass duration=${duration.inMilliseconds}ms '
            'withServices=${filter.withServices} withNamePrefix=${filter.withNamePrefix}',
      );
      _scanSubscription = UniversalBle.scanStream.listen((device) {
        passHits += handleDevice(device);
      });
      await UniversalBle.startScan(scanFilter: filter);
      try {
        await Future<void>.delayed(duration);
      } finally {
        try {
          await UniversalBle.stopScan();
        } catch (_) {}
        await _scanSubscription?.cancel();
        _scanSubscription = null;
      }
      _debugLog.debug('ble_scan', '$label scan pass complete hits=$passHits');
      return passHits;
    }

    try {
      if (kIsWeb) {
        final scanFilter = ScanFilter(
          withServices: const [_nusServiceUuid],
          withNamePrefix: namePrefixes,
        );
        await runScanPass(
          filter: scanFilter,
          duration: const Duration(milliseconds: 150),
          label: 'web',
        );
        // Web scan is an interactive picker request, not a continuous scan.
        // Do not hold scan state open for scanTimeout.
        return;
      }
      final totalMs = scanFor.inMilliseconds;
      final primaryMs = totalMs >= 6000 ? 6000 : totalMs;
      final fallbackMs = totalMs - primaryMs;
      final strictFilter = ScanFilter(
        withServices: const [_nusServiceUuid],
        withNamePrefix: namePrefixes,
      );
      final strictHits = await runScanPass(
        filter: strictFilter,
        duration: Duration(milliseconds: primaryMs),
        label: 'strict',
      );
      if (strictHits == 0 && fallbackMs > 0) {
        _debugLog.warn(
          'ble_scan',
          'No meshcore results from strict service-filter pass; '
              'starting broad fallback scan',
        );
        final broadFilter = ScanFilter(withNamePrefix: namePrefixes);
        await runScanPass(
          filter: broadFilter,
          duration: Duration(milliseconds: fallbackMs),
          label: 'fallback',
        );
      }
    } finally {
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      _scanInProgress = false;
      _debugLog.info('ble_scan', 'Scan stopped');
    }
  }

  bool _hasMeshCoreService(BleDevice device) {
    if (kIsWeb) {
      // Web picker already applies service filters in requestDevice().
      // The returned scan result may still have an empty `services` list.
      return true;
    }
    final targetDeviceId = (preferredDeviceId ?? '').trim();
    if (targetDeviceId.isNotEmpty && device.deviceId == targetDeviceId) {
      return true;
    }
    if (device.services.isNotEmpty) {
      for (final service in device.services) {
        final normalized = BleUuidParser.stringOrNull(service) ?? service;
        if (normalized == _meshCoreServiceUuidCanonical) {
          return true;
        }
      }
    }
    final advertisedName = (device.name ?? device.rawName ?? '')
        .trim()
        .toLowerCase();
    if (advertisedName.contains('meshcore') ||
        advertisedName.contains('meshcore-') ||
        advertisedName.contains('mesh core')) {
      return true;
    }
    for (final prefix in namePrefixes) {
      final normalizedPrefix = prefix.trim().toLowerCase();
      if (normalizedPrefix.isEmpty) continue;
      if (advertisedName.startsWith(normalizedPrefix)) return true;
    }
    return false;
  }

  Future<void> stopDeviceScan() async {
    if (!_scanInProgress) return;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _scanInProgress = false;
    _debugLog.info('ble_scan', 'Scan stopped (forced)');
  }

  Future<void> resetLinkState({String? deviceId}) async {
    final target = (deviceId ?? preferredDeviceId ?? _deviceId ?? '').trim();
    _debugLog.info(
      'ble_transport',
      'Resetting BLE link state target=${target.isEmpty ? 'none' : target}',
    );
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _scanInProgress = false;
    if (!kIsWeb && target.isNotEmpty) {
      try {
        await UniversalBle.disconnect(target);
        _debugLog.debug(
          'ble_transport',
          'Link-state reset disconnect attempted for $target',
        );
      } catch (_) {}
    }
    await _valueSubscription?.cancel();
    _valueSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _resetSessionState();
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  void _bindCharacteristics(List<BleService> services) {
    BleService? selectedService;
    BleCharacteristic? selectedWrite;
    BleCharacteristic? selectedNotify;

    for (final service in services) {
      BleCharacteristic? writeCandidate;
      BleCharacteristic? notifyCandidate;

      for (final characteristic in service.characteristics) {
        final props = characteristic.properties;

        if (writeCandidate == null &&
            props.contains(CharacteristicProperty.writeWithoutResponse)) {
          writeCandidate = characteristic;
        }
        if (writeCandidate == null &&
            props.contains(CharacteristicProperty.write)) {
          writeCandidate = characteristic;
        }

        if (notifyCandidate == null &&
            props.contains(CharacteristicProperty.notify)) {
          notifyCandidate = characteristic;
        }
        if (notifyCandidate == null &&
            props.contains(CharacteristicProperty.indicate)) {
          notifyCandidate = characteristic;
        }
      }

      if (writeCandidate != null && notifyCandidate != null) {
        selectedService = service;
        selectedWrite = writeCandidate;
        selectedNotify = notifyCandidate;
        break;
      }
    }

    if (selectedService == null ||
        selectedWrite == null ||
        selectedNotify == null) {
      _debugLog.error(
        'ble_transport',
        'No compatible write/notify characteristics found',
      );
      throw StateError(
        'Could not find compatible BLE write/notify characteristics',
      );
    }

    _serviceUuid = selectedService.uuid;
    _writeCharacteristicUuid = selectedWrite.uuid;
    _notifyCharacteristicUuid = selectedNotify.uuid;
    _writeWithoutResponse = selectedWrite.properties.contains(
      CharacteristicProperty.writeWithoutResponse,
    );
    _debugLog.info(
      'ble_transport',
      'Characteristics bound service=$_serviceUuid write=$_writeCharacteristicUuid notify=$_notifyCharacteristicUuid withoutResponse=$_writeWithoutResponse',
    );
  }

  void _bindKnownNusCharacteristics() {
    _serviceUuid = _nusServiceUuid;
    _writeCharacteristicUuid = _nusWriteUuid;
    _notifyCharacteristicUuid = _nusNotifyUuid;
    // Web Bluetooth paths are more reliable with response writes.
    _writeWithoutResponse = false;
    _debugLog.info(
      'ble_transport',
      'Characteristics bound by fallback service=$_serviceUuid write=$_writeCharacteristicUuid notify=$_notifyCharacteristicUuid withoutResponse=$_writeWithoutResponse',
    );
  }

  Future<void> _subscribeInbound() async {
    final currentDeviceId = _deviceId;
    final serviceUuid = _serviceUuid;
    final notifyCharacteristicUuid = _notifyCharacteristicUuid;

    if (currentDeviceId == null ||
        serviceUuid == null ||
        notifyCharacteristicUuid == null) {
      _debugLog.error(
        'ble_transport',
        'Inbound subscribe attempted before binding complete',
      );
      throw StateError('BLE characteristic binding incomplete');
    }

    await _valueSubscription?.cancel();
    _valueSubscription =
        UniversalBle.characteristicValueStream(
          currentDeviceId,
          notifyCharacteristicUuid,
        ).listen((value) {
          if (!_inboundController.isClosed) {
            _handleInboundChunk(value);
          }
        });

    try {
      await UniversalBle.subscribeNotifications(
        currentDeviceId,
        serviceUuid,
        notifyCharacteristicUuid,
      );
      _debugLog.info('ble_transport', 'Subscribed using notifications');
    } catch (_) {
      await UniversalBle.subscribeIndications(
        currentDeviceId,
        serviceUuid,
        notifyCharacteristicUuid,
      );
      _debugLog.info('ble_transport', 'Subscribed using indications');
    }
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _inboundController.close();
  }

  void _handleInboundChunk(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _appendInboundBytes(chunk);
  }

  void _appendInboundBytes(Uint8List bytes) {
    if (_rxAssembleCode != null &&
        _canFlushPartialOnBoundary(
          _rxAssembleCode!,
          _rxAssembleBuffer,
          bytes,
        )) {
      _inboundController.add(Uint8List.fromList(_rxAssembleBuffer));
      _clearRxAssembly();
    }

    if (_rxAssembleCode == null) {
      final code = bytes[0];
      if (!_isChunkProneCode(code)) {
        _inboundController.add(bytes);
        return;
      }
      _rxAssembleCode = code;
      _rxAssembleBuffer.clear();
      _contactStripChunkHeader = false;
      if (code == respCodeContact) {
        _appendContactChunk(bytes);
      } else {
        _rxAssembleBuffer.addAll(bytes);
      }
    } else {
      if (_rxAssembleCode == respCodeContact) {
        _appendContactChunk(bytes);
      } else {
        _rxAssembleBuffer.addAll(bytes);
      }
    }

    _rxAssembleExpectedLength = _expectedLengthForCode(
      _rxAssembleCode!,
      _rxAssembleBuffer,
    );

    if (_rxAssembleExpectedLength == null) {
      // Control frames expose payload length in header byte 3; wait for header.
      if (_rxAssembleBuffer.length > maxFrameSize * 3) {
        _debugLog.warn(
          'ble_transport_rx',
          'Dropping oversized partial frame code=$_rxAssembleCode bytes=${_rxAssembleBuffer.length}',
        );
        _clearRxAssembly();
      }
      return;
    }

    final expected = _rxAssembleExpectedLength!;
    if (_rxAssembleBuffer.length < expected) return;

    final frame = Uint8List.fromList(_rxAssembleBuffer.sublist(0, expected));
    _inboundController.add(frame);

    if (_rxAssembleBuffer.length == expected) {
      _clearRxAssembly();
      return;
    }

    final trailing = Uint8List.fromList(_rxAssembleBuffer.sublist(expected));
    _clearRxAssembly();
    _appendInboundBytes(trailing);
  }

  bool _isChunkProneCode(int code) {
    return code == respCodeContact ||
        code == pushCodeControlData ||
        code == pushCodeNewAdvert ||
        code == pushCodeAdvert;
  }

  int? _expectedLengthForCode(int code, List<int> bytes) {
    if (code == respCodeContact) return contactFrameSize;
    if (code == pushCodeControlData) {
      if (bytes.length < 4) return null;
      final declaredLen = bytes[3];
      if (declaredLen == 0 && bytes.length > 4) {
        // Some firmware sends control-data frames without a populated length
        // byte and streams payload inline in the same notification.
        return bytes.length;
      }
      return 4 + declaredLen;
    }
    if (code == pushCodeNewAdvert || code == pushCodeAdvert) {
      if (bytes.length < 4) return null;
      return 4 + bytes[3];
    }
    return null;
  }

  bool _canFlushPartialOnBoundary(
    int code,
    List<int> current,
    Uint8List incoming,
  ) {
    if (incoming.isEmpty) return false;
    if (code != respCodeSelfInfo && code != respCodeDeviceInfo) return false;
    if (current.length < 20) return false;
    return _looksLikeFrameStart(incoming[0]);
  }

  bool _looksLikeFrameStart(int code) {
    return code == respCodeOk ||
        code == respCodeErr ||
        code == respCodeContactsStart ||
        code == respCodeContact ||
        code == respCodeEndOfContacts ||
        code == respCodeSelfInfo ||
        code == respCodeDeviceInfo ||
        code == pushCodeControlData ||
        code == pushCodeAdvert ||
        code == pushCodeNewAdvert;
  }

  void _clearRxAssembly() {
    _rxAssembleBuffer.clear();
    _rxAssembleCode = null;
    _rxAssembleExpectedLength = null;
    _contactStripChunkHeader = false;
  }

  Future<void> _handleUnexpectedDisconnect(String reason) async {
    if (_manualDisconnectInProgress || _unexpectedResetInProgress) return;
    if (!_connected && _deviceId == null) return;
    _unexpectedResetInProgress = true;
    final lostDeviceId = _deviceId;
    _debugLog.warn(
      'ble_transport',
      'Connection lost for ${lostDeviceId ?? 'unknown'}: $reason',
    );
    try {
      await _valueSubscription?.cancel();
      _valueSubscription = null;
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;
      _resetSessionState();
      onConnectionStateChanged?.call(
        connected: false,
        deviceId: lostDeviceId,
        reason: reason,
      );
    } finally {
      _unexpectedResetInProgress = false;
    }
  }

  void _resetSessionState() {
    _connected = false;
    _deviceId = null;
    _serviceUuid = null;
    _writeCharacteristicUuid = null;
    _notifyCharacteristicUuid = null;
    _writeWithoutResponse = false;
    _clearRxAssembly();
  }

  void _appendContactChunk(Uint8List bytes) {
    if (_rxAssembleBuffer.isEmpty) {
      _rxAssembleBuffer.addAll(bytes);
      return;
    }
    if (!_contactStripChunkHeader &&
        bytes.length > 1 &&
        bytes[0] == respCodeContact) {
      // Android continuation notifications may repeat a 1-byte 0x03 marker.
      // Detect this on first continuation and strip for the remainder.
      _contactStripChunkHeader = true;
    }
    if (_contactStripChunkHeader && bytes.length > 1) {
      _rxAssembleBuffer.addAll(bytes.sublist(1));
      return;
    }
    _rxAssembleBuffer.addAll(bytes);
  }
}
