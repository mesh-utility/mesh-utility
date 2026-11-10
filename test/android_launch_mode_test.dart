import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MainActivity uses singleTask so notification taps resume one task', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');
    expect(manifest.existsSync(), isTrue);
    final text = manifest.readAsStringSync();
    expect(text, contains('android:launchMode="singleTask"'));
    expect(text.contains('android:taskAffinity=""'), isFalse);
    expect(text, isNot(contains('android:launchMode="singleTop"')));
  });

  test('MainActivity.onNewIntent updates the current intent', () {
    final kt = File(
      'android/app/src/main/kotlin/org/meshutility/app/MainActivity.kt',
    );
    expect(kt.existsSync(), isTrue);
    final text = kt.readAsStringSync();
    expect(text, contains('override fun onNewIntent(intent: Intent)'));
    expect(text, contains('setIntent(intent)'));
  });
}
