import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/main.dart';

void main() {
  test('Back on the first screen keeps the app running (radio stays)', () {
    // Finishing the activity makes Flutter report "detached", which
    // releases the radio. Back must move the task to the background
    // instead; only a swipe from recents closes the app.
    final src = File(
      'android/app/src/main/kotlin/org/meshutility/app/MainActivity.kt',
    ).readAsStringSync();
    final i = src.indexOf('override fun popSystemNavigator(): Boolean');
    expect(i, isNonNegative);
    final body = src.substring(i, src.indexOf('}', i));
    expect(body, contains('moveTaskToBack(true)'));
    expect(body, contains('return true'));
  });

  test('Back keeps the app running only on Android (not web)', () {
    expect(
      backKeepsAppRunning(isWeb: false, platform: TargetPlatform.android),
      isTrue,
    );
    expect(
      backKeepsAppRunning(isWeb: true, platform: TargetPlatform.android),
      isFalse,
    );
    expect(
      backKeepsAppRunning(isWeb: false, platform: TargetPlatform.linux),
      isFalse,
    );
  });

  test('Android side moves the task to the background on request', () {
    final src = File(
      'android/app/src/main/kotlin/org/meshutility/app/MainActivity.kt',
    ).readAsStringSync();
    expect(src, contains('"moveTaskToBack" ->'));
    expect(src, contains('result.success(moveTaskToBack(true))'));
  });

  test('closing the app (swipe away) ends the process to free the radio', () {
    final src = File(
      'android/app/src/main/kotlin/org/meshutility/app/MainActivity.kt',
    ).readAsStringSync();
    final i = src.indexOf('override fun onDestroy()');
    expect(i, isNonNegative);
    final body = src.substring(i, src.indexOf('\n    }\n', i));
    expect(body, contains('isFinishing && !isChangingConfigurations'));
    expect(body, contains('killProcess'));
  });
}
