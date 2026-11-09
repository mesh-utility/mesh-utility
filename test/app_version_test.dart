import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/app_version.dart';
import 'package:mesh_utility/src/services/update_check.dart';

void main() {
  test('generated fallback matches pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(kGeneratedAppVersion, match!.group(1));
    expect(alphaReleaseLabel(kGeneratedAppVersion), 'Alpha-23');
    expect(
      meshUtilityFooterLabel(kGeneratedAppVersion),
      'Mesh Utility Alpha-23',
    );
  });

  test('alpha label prefers prerelease over a mismatched build number', () {
    expect(
      versionLabelFromPackageInfo(version: 'Alpha-18', buildNumber: '1'),
      'Alpha-18',
    );
    expect(
      versionLabelFromPackageInfo(version: '1.0.0-alpha.18', buildNumber: '18'),
      '1.0.0-alpha.18+18',
    );
    expect(alphaReleaseLabel('1.0.0-alpha.18+18'), 'Alpha-18');
    expect(alphaReleaseLabel('1.0.0+18'), 'Alpha-18');
  });

  test('build number is used when the version name has no alpha token', () {
    expect(
      versionLabelFromPackageInfo(version: '1.0.0', buildNumber: '18'),
      'Alpha-18',
    );
    expect(
      versionLabelFromPackageInfo(version: '0.0.0', buildNumber: '0'),
      isNull,
    );
    expect(versionLabelFromPackageInfo(version: '', buildNumber: ''), isNull);
  });

  test('footer label and update checker agree on Alpha-N', () {
    const installed = '1.0.0-alpha.18+18';
    final fromPackage = versionLabelFromPackageInfo(
      version: '1.0.0-alpha.18',
      buildNumber: '18',
    );
    expect(fromPackage, installed);
    expect(meshUtilityFooterLabel(installed), 'Mesh Utility Alpha-18');
    expect(alphaReleaseLabel(fromPackage!), alphaReleaseLabel(installed));
    expect(
      isNewerAlphaRelease(currentVersion: installed, latestTag: 'Alpha-18'),
      isFalse,
    );
    expect(
      isNewerAlphaRelease(currentVersion: fromPackage, latestTag: 'Alpha-22'),
      isTrue,
    );
    expect(
      isNewerAlphaRelease(currentVersion: 'Alpha-18', latestTag: 'Alpha-18'),
      isFalse,
    );
  });

  test('native package info wins over the dart-define fallback', () async {
    final version = await resolveAppVersion(
      isWeb: false,
      readPackageInfo: () async =>
          (version: '1.0.0-alpha.21', buildNumber: '21'),
      environmentVersion: '1.0.0-alpha.3+3',
      generatedVersion: '1.0.0-alpha.1+1',
    );
    expect(version, '1.0.0-alpha.21+21');
    expect(alphaReleaseLabel(version), 'Alpha-21');
    expect(meshUtilityFooterLabel(version), 'Mesh Utility Alpha-21');
  });

  test('web ignores package info and uses APP_VERSION', () async {
    var calls = 0;
    final version = await resolveAppVersion(
      isWeb: true,
      readPackageInfo: () async {
        calls += 1;
        return (version: '9.9.9-alpha.9', buildNumber: '9');
      },
      environmentVersion: '1.0.0-alpha.4+4',
      generatedVersion: '1.0.0-alpha.1+1',
    );
    expect(calls, 0);
    expect(version, '1.0.0-alpha.4+4');
    expect(alphaReleaseLabel(version), 'Alpha-4');
  });

  test('web falls back to the generated constant', () async {
    final version = await resolveAppVersion(
      isWeb: true,
      environmentVersion: '',
      generatedVersion: '1.0.0-alpha.18+18',
    );
    expect(version, '1.0.0-alpha.18+18');
    expect(meshUtilityFooterLabel(version), 'Mesh Utility Alpha-18');
  });

  test(
    'placeholder package info falls back to APP_VERSION then generated',
    () async {
      final fromDefine = await resolveAppVersion(
        isWeb: false,
        readPackageInfo: () async => (version: '0.0.0', buildNumber: '0'),
        environmentVersion: '1.0.0-alpha.9+9',
        generatedVersion: '1.0.0-alpha.1+1',
      );
      expect(alphaReleaseLabel(fromDefine), 'Alpha-9');

      final fromGenerated = await resolveAppVersion(
        isWeb: false,
        readPackageInfo: () async => throw StateError('missing plugin'),
        environmentVersion: '   ',
        generatedVersion: '1.0.0-alpha.18+18',
      );
      expect(fromGenerated, '1.0.0-alpha.18+18');
      expect(
        isNewerAlphaRelease(
          currentVersion: fromGenerated,
          latestTag: 'Alpha-22',
        ),
        isTrue,
      );
    },
  );
}
