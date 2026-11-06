import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/update_check.dart';

void main() {
  group('parseAlphaNumber', () {
    test('parses Alpha-N tags and pubspec versions', () {
      expect(parseAlphaNumber('Alpha-17'), 17);
      expect(parseAlphaNumber('alpha-3'), 3);
      expect(parseAlphaNumber('1.0.0-alpha.17+17'), 17);
      expect(parseAlphaNumber('nope'), isNull);
    });
  });

  group('isNewerAlphaRelease', () {
    test('detects newer tags', () {
      expect(
        isNewerAlphaRelease(
          currentVersion: 'Alpha-16',
          latestTag: 'Alpha-17',
        ),
        isTrue,
      );
      expect(
        isNewerAlphaRelease(
          currentVersion: '1.0.0-alpha.17+17',
          latestTag: 'Alpha-17',
        ),
        isFalse,
      );
      expect(
        isNewerAlphaRelease(
          currentVersion: 'Alpha-17',
          latestTag: 'Alpha-16',
        ),
        isFalse,
      );
    });
  });

  group('sha256ForAsset', () {
    test('finds asset hash', () {
      const body = '''
aaa mesh-utility-Alpha-17-android.apk
bbb mesh-utility-Alpha-17-linux-x64.tar.gz
''';
      expect(
        sha256ForAsset(body, 'mesh-utility-Alpha-17-android.apk'),
        'aaa',
      );
      expect(sha256ForAsset(body, 'missing.apk'), isNull);
    });
  });
}
