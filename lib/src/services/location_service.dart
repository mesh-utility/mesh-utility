import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

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

  bool get _isLinuxDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

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
      _locationPollTimer?.cancel();
      _lastPreciseLocationAt = null;
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
              _log.error('location', 'Location stream error: $e');
              notifyListeners();
            },
          );
      deviceLocationStatus = 'Waiting for location fix...';
      notifyListeners();
      _locationPollTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => _pollLocationFallback(),
      );
      _log.info('location', 'Location tracking started');
    } catch (e) {
      deviceLocationStatus = 'Location unavailable';
      _log.error('location', 'Location setup failed: $e');
      notifyListeners();
    }
  }

  void stopTracking() {
    _locationSubscription?.cancel();
    _locationSubscription = null;
    _locationPollTimer?.cancel();
    _locationPollTimer = null;
  }

  /// Checks location permission/service on Android before BLE scan.
  /// Returns true when location is ready (or not needed).
  Future<bool> ensureAndroidReadyForBle() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        deviceLocationStatus = 'Location services disabled';
        _log.warn('location', '$deviceLocationStatus (BLE precheck)');
        notifyListeners();
        await Geolocator.openLocationSettings();
        return false;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
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
        await Geolocator.openAppSettings();
        return false;
      }

      // Android background permission requires a separate permission flow.
      final alwaysStatus = await ph.Permission.locationAlways.status;
      if (!alwaysStatus.isGranted) {
        final proceed =
            await (onLocationPermissionPrompt?.call(background: true) ??
                Future<bool>.value(true));
        if (!proceed) {
          deviceLocationStatus = 'Background location not requested';
          _log.warn('location', '$deviceLocationStatus (BLE precheck)');
          notifyListeners();
          return false;
        }
        final requestStatus = await ph.Permission.locationAlways.request();
        if (!requestStatus.isGranted) {
          deviceLocationStatus = 'Background location not granted';
          _log.warn('location', '$deviceLocationStatus (BLE precheck)');
          notifyListeners();
          if (requestStatus.isPermanentlyDenied) {
            await Geolocator.openAppSettings();
          }
          return false;
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
