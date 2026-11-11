import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/app_version.dart';
import 'package:mesh_utility/src/services/update_check.dart';

class _FixtureClient extends http.BaseClient {
  _FixtureClient(this.body);

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      request: request,
    );
  }
}

Map<String, Object?> _releaseJson(List<Map<String, String>> assets) {
  return <String, Object?>{
    'tag_name': 'Alpha-25',
    'name': 'Alpha-25',
    'html_url': 'https://example.test/Alpha-25',
    'body': 'notes',
    'draft': false,
    'prerelease': false,
    'assets': <Map<String, String>>[
      for (final asset in assets)
        <String, String>{
          'name': asset['name']!,
          'browser_download_url': asset['url']!,
        },
    ],
  };
}

Future<AppReleaseInfo?> _fetch(List<Map<String, String>> assets) {
  return fetchLatestRelease(
    client: _FixtureClient(jsonEncode(_releaseJson(assets))),
    uri: Uri.parse('https://example.test/releases/latest'),
  );
}

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
        isNewerAlphaRelease(currentVersion: 'Alpha-16', latestTag: 'Alpha-17'),
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
        isNewerAlphaRelease(currentVersion: 'Alpha-17', latestTag: 'Alpha-16'),
        isFalse,
      );
    });

    test('treats Alpha-25.1 as newer than Alpha-25', () {
      expect(
        isNewerAlphaRelease(
          currentVersion: '1.0.0-alpha.25+25',
          latestTag: 'Alpha-25.1',
        ),
        isTrue,
      );
      expect(
        isNewerAlphaRelease(
          currentVersion: 'Alpha-25',
          latestTag: '1.0.0-alpha.25.1+26',
        ),
        isTrue,
      );
      expect(
        isNewerAlphaRelease(
          currentVersion: '1.0.0-alpha.25.1+26',
          latestTag: 'Alpha-25',
        ),
        isFalse,
      );
      expect(
        isNewerAlphaRelease(
          currentVersion: 'Alpha-25.1',
          latestTag: 'Alpha-25.1',
        ),
        isFalse,
      );
      expect(
        isNewerAlphaRelease(
          currentVersion: 'Alpha-25.1',
          latestTag: 'Alpha-26',
        ),
        isTrue,
      );
    });

    test('treats Alpha-25.2 as newer than Alpha-25.1', () {
      expect(
        isNewerAlphaRelease(
          currentVersion: '1.0.0-alpha.25.1+26',
          latestTag: 'Alpha-25.2',
        ),
        isTrue,
      );
      expect(
        isNewerAlphaRelease(
          currentVersion: 'Alpha-25.1',
          latestTag: '1.0.0-alpha.25.2+27',
        ),
        isTrue,
      );
      expect(
        isNewerAlphaRelease(
          currentVersion: '1.0.0-alpha.25.2+27',
          latestTag: 'Alpha-25.1',
        ),
        isFalse,
      );
      expect(
        isNewerAlphaRelease(
          currentVersion: 'Alpha-25.2',
          latestTag: 'Alpha-25.2',
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
      expect(sha256ForAsset(body, 'mesh-utility-Alpha-17-android.apk'), 'aaa');
      expect(sha256ForAsset(body, 'missing.apk'), isNull);
    });
  });

  group('fetchLatestRelease assets', () {
    test('release with no assets is not installable', () async {
      final release = await _fetch(const <Map<String, String>>[]);
      expect(release, isNotNull);
      expect(release!.androidApkUrl, isNull);
      expect(release.linuxArchiveUrl, isNull);
      expect(release.sha256SumsUrl, isNull);
      expect(
        releaseHasInstallableAsset(release, TargetPlatform.android),
        isFalse,
      );
      expect(
        releaseHasInstallableAsset(release, TargetPlatform.linux),
        isFalse,
      );
    });

    test('checksums alone are not installable', () async {
      final release = await _fetch(const <Map<String, String>>[
        <String, String>{
          'name': 'SHA256SUMS.txt',
          'url': 'https://example.test/SHA256SUMS.txt',
        },
        <String, String>{
          'name': 'mesh-utility-Alpha-25-windows-x64.zip',
          'url': 'https://example.test/windows.zip',
        },
      ]);
      expect(release!.sha256SumsUrl, 'https://example.test/SHA256SUMS.txt');
      expect(release.androidApkUrl, isNull);
      expect(release.linuxArchiveUrl, isNull);
      expect(
        releaseHasInstallableAsset(release, TargetPlatform.android),
        isFalse,
      );
      expect(
        releaseHasInstallableAsset(release, TargetPlatform.linux),
        isFalse,
      );
    });

    test('apk plus checksums installs on Android only', () async {
      final release = await _fetch(const <Map<String, String>>[
        <String, String>{
          'name': 'mesh-utility-Alpha-25-android.apk',
          'url': 'https://example.test/app.apk',
        },
        <String, String>{
          'name': 'SHA256SUMS.txt',
          'url': 'https://example.test/SHA256SUMS.txt',
        },
        <String, String>{
          'name': 'other-android.apk',
          'url': 'https://example.test/other.apk',
        },
      ]);
      expect(release!.androidApkUrl, 'https://example.test/app.apk');
      expect(release.linuxArchiveUrl, isNull);
      expect(
        releaseHasInstallableAsset(release, TargetPlatform.android),
        isTrue,
      );
      expect(
        releaseHasInstallableAsset(release, TargetPlatform.linux),
        isFalse,
      );
      expect(
        releaseHasInstallableAsset(release, TargetPlatform.windows),
        isFalse,
      );
    });

    test('linux archive plus checksums installs on Linux only', () async {
      final release = await _fetch(const <Map<String, String>>[
        <String, String>{
          'name': 'mesh-utility-Alpha-25-linux-x64.tar.gz',
          'url': 'https://example.test/app.tar.gz',
        },
        <String, String>{
          'name': 'SHA256SUMS.txt',
          'url': 'https://example.test/SHA256SUMS.txt',
        },
      ]);
      expect(release!.linuxArchiveUrl, 'https://example.test/app.tar.gz');
      expect(release.androidApkUrl, isNull);
      expect(releaseHasInstallableAsset(release, TargetPlatform.linux), isTrue);
      expect(
        releaseHasInstallableAsset(release, TargetPlatform.android),
        isFalse,
      );
    });

    test('apk without checksums is not installable', () async {
      final release = await _fetch(const <Map<String, String>>[
        <String, String>{
          'name': 'mesh-utility-Alpha-25-android.apk',
          'url': 'https://example.test/app.apk',
        },
      ]);
      expect(release!.androidApkUrl, isNotNull);
      expect(
        releaseHasInstallableAsset(release, TargetPlatform.android),
        isFalse,
      );
    });
  });

  group('decideUpdateAvailability', () {
    AppReleaseInfo release({
      String? apk,
      String? linux,
      String? sums,
      String tag = 'Alpha-25',
    }) {
      return AppReleaseInfo(
        tagName: tag,
        name: tag,
        htmlUrl: 'https://example.test/$tag',
        body: '',
        alphaNumber: 25,
        androidApkUrl: apk,
        linuxArchiveUrl: linux,
        sha256SumsUrl: sums,
      );
    }

    test('newer release with no assets is not offered', () {
      final quiet = decideUpdateAvailability(
        latest: release(),
        currentVersion: 'Alpha-24',
        skippedTag: null,
        force: false,
        platform: TargetPlatform.android,
      );
      expect(quiet.release, isNull);
      expect(quiet.statusMessage, isNull);

      final forced = decideUpdateAvailability(
        latest: release(),
        currentVersion: 'Alpha-24',
        skippedTag: 'Alpha-25',
        force: true,
        platform: TargetPlatform.android,
      );
      expect(forced.release, isNull);
      expect(forced.statusMessage, updateStillUploadingMessage);
    });

    test('only checksums stays unavailable on force', () {
      final decision = decideUpdateAvailability(
        latest: release(sums: 'https://example.test/SHA256SUMS.txt'),
        currentVersion: 'Alpha-24',
        skippedTag: null,
        force: true,
        platform: TargetPlatform.linux,
      );
      expect(decision.release, isNull);
      expect(decision.statusMessage, updateStillUploadingMessage);
    });

    test('android apk is available on Android and not on Linux', () {
      final latest = release(
        apk: 'https://example.test/app.apk',
        sums: 'https://example.test/SHA256SUMS.txt',
      );
      final android = decideUpdateAvailability(
        latest: latest,
        currentVersion: 'Alpha-24',
        skippedTag: null,
        force: false,
        platform: TargetPlatform.android,
      );
      expect(android.release, same(latest));
      expect(android.statusMessage, 'Update available: Alpha-25');

      final linux = decideUpdateAvailability(
        latest: latest,
        currentVersion: 'Alpha-24',
        skippedTag: null,
        force: true,
        platform: TargetPlatform.linux,
      );
      expect(linux.release, isNull);
      expect(linux.statusMessage, updateStillUploadingMessage);
    });

    test('linux archive is available on Linux and not on Android', () {
      final latest = release(
        linux: 'https://example.test/app.tar.gz',
        sums: 'https://example.test/SHA256SUMS.txt',
      );
      final linux = decideUpdateAvailability(
        latest: latest,
        currentVersion: '1.0.0-alpha.24+24',
        skippedTag: null,
        force: true,
        platform: TargetPlatform.linux,
      );
      expect(linux.release?.linuxArchiveUrl, isNotNull);
      expect(linux.statusMessage, 'Update available: Alpha-25');

      final android = decideUpdateAvailability(
        latest: latest,
        currentVersion: 'Alpha-24',
        skippedTag: null,
        force: false,
        platform: TargetPlatform.android,
      );
      expect(android.release, isNull);
      expect(android.statusMessage, isNull);
    });

    test('current tag is up to date even with no assets', () {
      final decision = decideUpdateAvailability(
        latest: release(tag: 'Alpha-24'),
        currentVersion: 'Alpha-24',
        skippedTag: null,
        force: true,
        platform: TargetPlatform.android,
      );
      expect(decision.release, isNull);
      expect(decision.statusMessage, 'Up to date (Alpha-24).');
    });

    test('up to date names the running version, not an older latest tag', () {
      final decision = decideUpdateAvailability(
        latest: release(tag: 'Alpha-24'),
        currentVersion: '1.0.0-alpha.25+25',
        skippedTag: null,
        force: true,
        platform: TargetPlatform.android,
      );
      expect(decision.release, isNull);
      expect(decision.statusMessage, 'Up to date (Alpha-25).');
      expect(decision.statusMessage, isNot(contains('Alpha-24')));
    });

    test('skipped installable tag stays hidden until a forced check', () {
      final latest = release(
        apk: 'https://example.test/app.apk',
        sums: 'https://example.test/SHA256SUMS.txt',
      );
      final quiet = decideUpdateAvailability(
        latest: latest,
        currentVersion: 'Alpha-24',
        skippedTag: 'Alpha-25',
        force: false,
        platform: TargetPlatform.android,
      );
      expect(quiet.release, isNull);
      expect(quiet.statusMessage, isNull);

      final forced = decideUpdateAvailability(
        latest: latest,
        currentVersion: 'Alpha-24',
        skippedTag: 'Alpha-25',
        force: true,
        platform: TargetPlatform.android,
      );
      expect(forced.release, same(latest));
    });
  });
}
