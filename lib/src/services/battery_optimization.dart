import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Status line shown under Settings → Scanning on Android.
String batteryOptimizationStatusLabel({required bool ignoring}) {
  return ignoring
      ? 'Battery optimization: Unrestricted'
      : 'Battery optimization: Optimized';
}

bool get _isAndroidNative =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// True when Android is not restricting this app.
///
/// Non-Android platforms are treated as unrestricted so callers can skip the
/// prompt. A plugin failure is reported to the caller.
Future<bool> isIgnoringBatteryOptimizations() async {
  if (!_isAndroidNative) return true;
  final status = await Permission.ignoreBatteryOptimizations.status;
  return status.isGranted;
}

/// Opens the system "ignore battery optimizations" screen for this package.
Future<bool> requestIgnoreBatteryOptimizations() async {
  if (!_isAndroidNative) return false;
  final status = await Permission.ignoreBatteryOptimizations.request();
  return status.isGranted;
}

/// Opens app settings when the app is already unrestricted, or the system
/// exemption screen when it is still optimized.
Future<void> requestOrOpenBatteryOptimizationSettings({
  required bool ignoring,
}) async {
  if (!_isAndroidNative) return;
  if (ignoring) {
    await openAppSettings();
    return;
  }
  await Permission.ignoreBatteryOptimizations.request();
}
