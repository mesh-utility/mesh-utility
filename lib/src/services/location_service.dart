import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/scan_foreground_mode.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

ForegroundNotificationConfig _scanForegroundNotification({
  required bool reconnecting,
}) {
  return ForegroundNotificationConfig(
    notificationTitle: 'Mesh Utility scanning',
    notificationText: reconnecting
        ? 'Reconnecting to radio…'
        : 'Scanning for mesh coverage in the background',
    notificationChannelName: 'Mesh scanning',
    enableWakeLock: true,
    setOngoing: true,
  );
}

/// Owns GPS + IP-fallback location tracking.
///
/// Callers should wire [onPositionChanged] before calling [startTracking] to
/// be notified whenever a new position is applied.
class LocationService extends ChangeNotifier {
  final _log = AppDebugLogService.instance;

  /// Called (with background: true/false) when Android permission prompts are
  /// needed. Return false to skip requesting the permission.
  Future<bool> Function({required bool background})? onLocationPermissionPrompt;

  /// Called after every position update (GPS or IP-fallback).
  void Function(double lat, double lng)? onPositionChanged;

  double? deviceLatitude;
  double? deviceLongitude;
  double? deviceAltitude;
  DateTime? deviceLocationAt;
  String deviceLocationStatus = 'Location unavailable';

  StreamSubscription<Position>? _locationSubscription;
  Timer? _locationPollTimer;
  DateTime? _lastIpFallbackAt;
  DateTime? _lastPreciseLocationAt;
  bool _discoverLocationRefreshInFlight = false;
  DateTime? _lastDiscoverLocationRefreshAt;

  bool _trackingActive = false;
  bool _scanLoopRunning = false;
  bool _scanBleConnected = false;
  bool _scanLoopWanted = false;
  bool _scanReconnecting = false;
  bool _requestedWhileInForeground = false;
  bool _appliedForeground = false;
  bool _appliedReconnecting = false;
  bool _foregroundSuppressed = false;
  bool _loggedKeptNotificationWhileReconnecting = false;
  int _streamGeneration = 0;
  Future<void> _streamApply = Future<void>.value();

  bool get _isLinuxDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  bool get _isAndroidNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> startTracking() async {
    try {
      _log.info('location', 'Starting OS location tracking');
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        deviceLocationStatus = 'Location services disabled';
        _log.warn('location', deviceLocationStatus);
        notifyListeners();
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          final proceed =
              await (onLocationPermissionPrompt?.call(background: false) ??
                  Future<bool>.value(true));
          if (!proceed) {
            deviceLocationStatus = 'Location permission not requested';
            _log.warn('location', deviceLocationStatus);
            notifyListeners();
            return;
          }
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        deviceLocationStatus = 'Location permission denied';
        _log.warn('location', deviceLocationStatus);
        notifyListeners();
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        deviceLocationStatus = 'Location permission denied forever';
        _log.warn('location', deviceLocationStatus);
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
        _log.warn('location', 'Initial location fetch failed: $e');
        await _tryIpFallbackLocation();
      }

      await _locationSubscription?.cancel();
      _locationSubscription = null;
      _locationPollTimer?.cancel();
      _lastPreciseLocationAt = null;
      _trackingActive = true;
      final keepAlive =
          _scanLoopWanted || (_scanLoopRunning && _scanBleConnected);
      if (keepAlive && _androidUiInForeground()) {
        _requestedWhileInForeground = true;
      }
      deviceLocationStatus = 'Waiting for location fix...';
      notifyListeners();
      _locationPollTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => _pollLocationFallback(),
      );
      await _enqueueStreamApply();
      _log.info('location', 'Location tracking started');
    } catch (e) {
      deviceLocationStatus = 'Location unavailable';
      _log.error('location', 'Location setup failed: $e');
      notifyListeners();
    }
  }

  void stopTracking() {
    _trackingActive = false;
    _scanLoopRunning = false;
    _scanBleConnected = false;
    _scanLoopWanted = false;
    _scanReconnecting = false;
    _appliedForeground = false;
    _appliedReconnecting = false;
    _foregroundSuppressed = false;
    _loggedKeptNotificationWhileReconnecting = false;
    _streamGeneration++;
    _locationSubscription?.cancel();
    _locationSubscription = null;
    _locationPollTimer?.cancel();
    _locationPollTimer = null;
  }

  /// Match the position stream to the scan loop.
  ///
  /// On Android, a wanted loop resubscribes with geolocator's foreground
  /// notification and partial wake lock. The service stays up while the radio
  /// is reconnecting ([loopWanted] true, [bleConnected] false) so the phone
  /// does not drop the process with the screen off. Pausing the loop, a
  /// manual disconnect, or abandoning reconnect ([loopWanted] false) returns
  /// to the normal stream. Other platforms no-op.
  ///
  /// Safe to call before [startTracking]: the choice is stored and applied
  /// once tracking is up. Plugin calls are skipped until then so unit tests
  /// that never start tracking do not touch platform channels.
  Future<void> syncScanLoopForeground({
    required bool scanLoopRunning,
    required bool bleConnected,
    bool loopWanted = false,
  }) {
    _scanLoopRunning = scanLoopRunning;
    _scanBleConnected = bleConnected;
    _scanLoopWanted = loopWanted;
    _scanReconnecting = loopWanted && !bleConnected;
    final keepAlive = loopWanted || (scanLoopRunning && bleConnected);
    if (!keepAlive) {
      _foregroundSuppressed = false;
    }
    if (!_isAndroidNative || !_trackingActive) {
      return Future<void>.value();
    }
    // Only raise the latch while the UI is visible. A reconnect with the
    // screen off must not clear a latch captured when the user started the
    // loop, or the service would stop the moment the link drops.
    if (keepAlive && _androidUiInForeground()) {
      _requestedWhileInForeground = true;
    }
    return _enqueueStreamApply();
  }

  /// Checks location permission/service on Android before BLE scan.
  /// Returns true when location is ready (or not needed).
  ///
  /// [prompt] false skips every dialog and settings screen. Background
  /// reconnect uses that so a screen-off retry cannot wait on the UI.
  Future<bool> ensureAndroidReadyForBle({bool prompt = true}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        deviceLocationStatus = 'Location services disabled';
        _log.warn('location', '$deviceLocationStatus (BLE precheck)');
        notifyListeners();
        if (prompt) {
          await Geolocator.openLocationSettings();
        }
        return false;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (!prompt) {
          deviceLocationStatus = 'Location permission denied';
          _log.warn(
            'location',
            'Location permission missing; background reconnect will not '
                'show a prompt',
          );
          notifyListeners();
          return false;
        }
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          final proceed =
              await (onLocationPermissionPrompt?.call(background: false) ??
                  Future<bool>.value(true));
          if (!proceed) {
            deviceLocationStatus = 'Location permission not requested';
            _log.warn('location', '$deviceLocationStatus (BLE precheck)');
            notifyListeners();
            return false;
          }
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        deviceLocationStatus = 'Location permission denied';
        _log.warn('location', '$deviceLocationStatus (BLE precheck)');
        notifyListeners();
        return false;
      }
      if (permission == LocationPermission.deniedForever) {
        deviceLocationStatus = 'Location permission denied forever';
        _log.warn('location', '$deviceLocationStatus (BLE precheck)');
        notifyListeners();
        if (prompt) {
          await Geolocator.openAppSettings();
        }
        return false;
      }

      if (!prompt) {
        return true;
      }

      // Background location is a separate prompt. A location foreground
      // service started while the app is visible does not need it, so a
      // denial must not block connect or the scan loop.
      final alwaysStatus = await ph.Permission.locationAlways.status;
      if (!alwaysStatus.isGranted) {
        final proceed =
            await (onLocationPermissionPrompt?.call(background: true) ??
                Future<bool>.value(true));
        if (!proceed) {
          _log.warn(
            'location',
            'Background location not requested; the scan loop can still '
                'start in the foreground with the scanning notification',
          );
        } else {
          final requestStatus = await ph.Permission.locationAlways.request();
          if (!requestStatus.isGranted) {
            _log.warn(
              'location',
              'Background location not granted; the scan loop can still '
                  'start in the foreground with the scanning notification',
            );
          }
        }
      }
      return true;
    } catch (e) {
      _log.warn('location', 'BLE location precheck failed: $e');
      return true;
    }
  }

  /// One-shot high-accuracy position refresh used during discover responses.
  Future<void> refreshForDiscoverResponse() async {
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

  bool _androidUiInForeground() {
    try {
      return androidUiIsInForeground(WidgetsBinding.instance.lifecycleState);
    } catch (e) {
      _log.warn(
        'location',
        'App lifecycle unavailable ($e); assuming the scan loop started '
            'in the foreground',
      );
      return true;
    }
  }

  Future<void> _enqueueStreamApply() {
    final run = _streamApply.then((_) async {
      try {
        await _applyScanForegroundModeBody();
      } catch (e, stack) {
        _log.error('location', 'Position stream update failed: $e\n$stack');
      }
    });
    _streamApply = run;
    return run;
  }

  Future<void> _applyScanForegroundModeBody() async {
    if (!_trackingActive) return;
    final hold = await _resolveForegroundHold();
    if (!_trackingActive) return;
    final reconnecting = _scanReconnecting;
    if (!hold || !reconnecting) {
      _loggedKeptNotificationWhileReconnecting = false;
    }
    final sameMode =
        hold == _appliedForeground &&
        _locationSubscription != null &&
        (!hold || reconnecting == _appliedReconnecting);
    if (sameMode) return;
    // Cancelling the stream calls stopForeground. On an aggressive phone
    // that gap is enough to lose the process while the screen is off, so a
    // service that is already up keeps its current notification text.
    if (hold &&
        _appliedForeground &&
        _locationSubscription != null &&
        reconnecting &&
        !_appliedReconnecting) {
      if (!_loggedKeptNotificationWhileReconnecting) {
        _loggedKeptNotificationWhileReconnecting = true;
        _log.info(
          'location',
          'Keeping the scan notification up while the radio reconnects',
        );
      }
      return;
    }
    await _listenPositionStream(holdForeground: hold);
  }

  Future<bool> _resolveForegroundHold() async {
    final keepAlive =
        _scanLoopWanted || (_scanLoopRunning && _scanBleConnected);
    if (_foregroundSuppressed || !keepAlive) {
      return false;
    }
    var whileInUseGranted = false;
    try {
      final permission = await Geolocator.checkPermission();
      whileInUseGranted =
          permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (e) {
      _log.warn('location', 'Location permission check failed: $e');
    }
    if (!_trackingActive) return false;
    if (!whileInUseGranted) {
      _log.warn(
        'location',
        'While-in-use location is missing; not starting the scan '
            'foreground service',
      );
      return false;
    }
    var backgroundGranted = false;
    try {
      final status = await ph.Permission.locationAlways.status;
      backgroundGranted = status.isGranted;
    } catch (e) {
      _log.warn('location', 'Background location check failed: $e');
    }
    if (!_trackingActive) return false;
    final hold = shouldHoldAndroidScanForeground(
      isAndroidNative: true,
      scanLoopRunning: _scanLoopRunning,
      bleConnected: _scanBleConnected,
      loopWanted: _scanLoopWanted,
      backgroundLocationGranted: backgroundGranted,
      appInForeground: _requestedWhileInForeground,
    );
    if (hold && !backgroundGranted) {
      _log.info(
        'location',
        'Background location is not granted; starting the scan foreground '
            'notification because the loop started in the foreground',
      );
    } else if (!hold) {
      _log.warn(
        'location',
        'Scan loop is wanted in the background without background '
            'location; not starting the foreground service',
      );
    }
    return hold;
  }

  LocationSettings _positionStreamSettings({required bool foreground}) {
    if (!foreground) {
      return const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      );
    }
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
      foregroundNotificationConfig: _scanForegroundNotification(
        reconnecting: _scanReconnecting,
      ),
    );
  }

  Future<void> _listenPositionStream({required bool holdForeground}) async {
    final generation = ++_streamGeneration;
    await _locationSubscription?.cancel();
    if (!_trackingActive || generation != _streamGeneration) return;
    try {
      _locationSubscription =
          Geolocator.getPositionStream(
            locationSettings: _positionStreamSettings(
              foreground: holdForeground,
            ),
          ).listen(
            (position) => _applyDevicePosition(position, source: 'stream'),
            onError: (Object e) {
              if (generation != _streamGeneration) return;
              _handlePositionStreamError(e, holdForeground: holdForeground);
            },
          );
      final previous = _appliedForeground;
      _appliedForeground = holdForeground;
      _appliedReconnecting = holdForeground && _scanReconnecting;
      if (previous != holdForeground) {
        _log.info(
          'location',
          holdForeground
              ? (_scanReconnecting
                    ? 'Scan foreground service on while reconnecting '
                          '(notification + wake lock)'
                    : 'Scan foreground service on (notification + wake lock)')
              : 'Scan foreground service off',
        );
      }
    } catch (e, stack) {
      _locationSubscription = null;
      _appliedForeground = false;
      _appliedReconnecting = false;
      _log.error('location', 'Position stream subscribe failed: $e\n$stack');
      if (holdForeground && _trackingActive) {
        _foregroundSuppressed = true;
        await _listenPositionStream(holdForeground: false);
      }
    }
  }

  void _handlePositionStreamError(Object e, {required bool holdForeground}) {
    if (!holdForeground) {
      deviceLocationStatus = 'Location stream error';
      _log.error('location', 'Location stream error: $e');
      notifyListeners();
      return;
    }
    _log.error(
      'location',
      'Scan foreground stream failed; continuing without it: $e',
    );
    _foregroundSuppressed = true;
    _appliedForeground = false;
    _appliedReconnecting = false;
    _streamGeneration++;
    unawaited(_locationSubscription?.cancel());
    _locationSubscription = null;
    unawaited(_enqueueStreamApply());
  }

  void _applyDevicePosition(Position position, {required String source}) {
    deviceLatitude = position.latitude;
    deviceLongitude = position.longitude;
    deviceAltitude = position.altitude;
    deviceLocationAt = DateTime.now();
    _lastPreciseLocationAt = deviceLocationAt;
    deviceLocationStatus = 'Location active';
    _log.info(
      'location',
      '$source lat=${position.latitude.toStringAsFixed(6)} '
          'lng=${position.longitude.toStringAsFixed(6)} '
          'alt=${position.altitude.toStringAsFixed(1)}',
    );
    notifyListeners();
    onPositionChanged?.call(position.latitude, position.longitude);
  }

  Future<void> _pollLocationFallback() async {
    final lastPrecise = _lastPreciseLocationAt;
    if (lastPrecise != null &&
        DateTime.now().difference(lastPrecise) < const Duration(seconds: 45)) {
      return;
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 0,
        ),
      ).timeout(const Duration(seconds: 6));
      _applyDevicePosition(pos, source: 'poll');
    } catch (e) {
      _log.debug('location', 'Fallback poll no fix yet: $e');
      await _tryIpFallbackLocation();
    }
  }

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
      _log.info(
        'location',
        'ip-fallback lat=${lat.toStringAsFixed(6)} lng=${lon.toStringAsFixed(6)}',
      );
      notifyListeners();
      onPositionChanged?.call(lat, lon);
    } catch (e) {
      _log.debug('location', 'IP fallback failed: $e');
    }
  }

  @override
  void dispose() {
    stopTracking();
    super.dispose();
  }
}
