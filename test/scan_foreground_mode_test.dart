import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/battery_optimization.dart';
import 'package:mesh_utility/src/services/scan_foreground_mode.dart';

void main() {
  bool hold({
    bool isAndroidNative = true,
    bool scanLoopRunning = true,
    bool bleConnected = true,
    bool backgroundLocationGranted = true,
    bool appInForeground = true,
    bool loopWanted = false,
  }) {
    return shouldHoldAndroidScanForeground(
      isAndroidNative: isAndroidNative,
      scanLoopRunning: scanLoopRunning,
      bleConnected: bleConnected,
      backgroundLocationGranted: backgroundLocationGranted,
      appInForeground: appInForeground,
      loopWanted: loopWanted,
    );
  }

  test('foreground mode is on only while Android scan loop and BLE are up', () {
    expect(hold(), isTrue);
    expect(hold(isAndroidNative: false), isFalse);
    expect(hold(scanLoopRunning: false), isFalse);
    expect(hold(bleConnected: false), isFalse);
    expect(
      hold(scanLoopRunning: false, bleConnected: false, appInForeground: true),
      isFalse,
    );
  });

  test(
    'missing background location still holds when the loop starts in front',
    () {
      expect(
        hold(backgroundLocationGranted: false, appInForeground: true),
        isTrue,
      );
      expect(
        hold(backgroundLocationGranted: false, appInForeground: false),
        isFalse,
      );
      expect(
        hold(backgroundLocationGranted: true, appInForeground: false),
        isTrue,
      );
    },
  );

  test('paused or disconnected loop does not hold without a running link', () {
    expect(
      hold(
        scanLoopRunning: false,
        backgroundLocationGranted: false,
        appInForeground: true,
      ),
      isFalse,
    );
    expect(
      hold(
        bleConnected: false,
        backgroundLocationGranted: false,
        appInForeground: true,
      ),
      isFalse,
    );
  });

  test('a wanted loop holds through a radio reconnect', () {
    expect(
      hold(scanLoopRunning: false, bleConnected: false, loopWanted: true),
      isTrue,
    );
    expect(
      hold(
        scanLoopRunning: false,
        bleConnected: false,
        loopWanted: true,
        backgroundLocationGranted: false,
        appInForeground: true,
      ),
      isTrue,
    );
    expect(
      hold(
        scanLoopRunning: false,
        bleConnected: false,
        loopWanted: true,
        backgroundLocationGranted: true,
        appInForeground: false,
      ),
      isTrue,
    );
    expect(
      hold(
        scanLoopRunning: false,
        bleConnected: false,
        loopWanted: true,
        backgroundLocationGranted: false,
        appInForeground: false,
      ),
      isFalse,
    );
    expect(
      hold(
        scanLoopRunning: false,
        bleConnected: false,
        loopWanted: true,
        isAndroidNative: false,
      ),
      isFalse,
    );
    expect(hold(loopWanted: false, scanLoopRunning: false), isFalse);
    expect(
      hold(loopWanted: false, bleConnected: false, scanLoopRunning: false),
      isFalse,
    );
  });

  test('scan reconnect backoff grows then caps at 60 seconds', () {
    expect(scanReconnectBackoffDelay(0), const Duration(seconds: 2));
    expect(scanReconnectBackoffDelay(1), const Duration(seconds: 5));
    expect(scanReconnectBackoffDelay(2), const Duration(seconds: 10));
    expect(scanReconnectBackoffDelay(3), const Duration(seconds: 20));
    expect(scanReconnectBackoffDelay(4), const Duration(seconds: 30));
    expect(scanReconnectBackoffDelay(5), const Duration(seconds: 60));
    expect(scanReconnectBackoffDelay(6), const Duration(seconds: 60));
    expect(scanReconnectBackoffDelay(100), const Duration(seconds: 60));
    expect(scanReconnectBackoffDelay(-1), const Duration(seconds: 2));
  });

  test('battery optimization status uses the settings labels', () {
    expect(
      batteryOptimizationStatusLabel(ignoring: true),
      'Battery optimization: Unrestricted',
    );
    expect(
      batteryOptimizationStatusLabel(ignoring: false),
      'Battery optimization: Optimized',
    );
  });

  test('only a resumed or not-yet-reported UI may start the service', () {
    expect(androidUiIsInForeground(null), isTrue);
    expect(androidUiIsInForeground(AppLifecycleState.resumed), isTrue);
    expect(androidUiIsInForeground(AppLifecycleState.inactive), isFalse);
    expect(androidUiIsInForeground(AppLifecycleState.hidden), isFalse);
    expect(androidUiIsInForeground(AppLifecycleState.paused), isFalse);
    expect(androidUiIsInForeground(AppLifecycleState.detached), isFalse);
  });
}
