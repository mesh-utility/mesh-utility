import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// `--dart-define=APP_VERSION=1.0.0-alpha.N+N`.
///
/// Web builds pass this because `package_info_plus` loads `version.json`
/// from the server (cache-busted), which can be a newer deploy than the
/// bundle that is actually running.
const String kAppVersionFromEnvironment = String.fromEnvironment('APP_VERSION');

/// Last-resort copy of pubspec `version:`.
///
/// Native builds prefer [PackageInfo]. Web builds prefer [kAppVersionFromEnvironment].
/// `test/app_version_test.dart` fails if this drifts from pubspec.yaml.
const String kGeneratedAppVersion = '1.0.0-alpha.18+18';

/// Version known at startup, before [loadAppVersion] finishes.
String get kAppVersionLabel {
  final env = kAppVersionFromEnvironment.trim();
  if (env.isNotEmpty) return env;
  return kGeneratedAppVersion;
}

/// `Alpha-N` for [kAppVersionLabel].
String get kAppAlphaLabel => alphaReleaseLabel(kAppVersionLabel);

typedef PackageVersionReader =
    Future<({String version, String buildNumber})> Function();

String? _cachedAppVersion;
Future<String>? _loadingAppVersion;

/// Full version string shared by the side nav and the update checker.
///
/// Non-web: package_info (the version Flutter stamped into this build),
/// then `APP_VERSION`, then [kGeneratedAppVersion].
/// Web: skip package_info and use `APP_VERSION`, then [kGeneratedAppVersion].
Future<String> loadAppVersion() {
  final cached = _cachedAppVersion;
  if (cached != null) return Future<String>.value(cached);
  return _loadingAppVersion ??= resolveAppVersion().then((version) {
    _cachedAppVersion = version;
    return version;
  });
}

/// Resolves the version string. Tests pass [isWeb] and [readPackageInfo].
Future<String> resolveAppVersion({
  bool? isWeb,
  PackageVersionReader? readPackageInfo,
  String? environmentVersion,
  String? generatedVersion,
}) async {
  final web = isWeb ?? kIsWeb;
  final env = (environmentVersion ?? kAppVersionFromEnvironment).trim();
  final generated = (generatedVersion ?? kGeneratedAppVersion).trim();

  if (!web) {
    try {
      final info = await (readPackageInfo ?? _readPackageInfoVersion)();
      final resolved = versionLabelFromPackageInfo(
        version: info.version,
        buildNumber: info.buildNumber,
      );
      if (resolved != null && resolved.isNotEmpty) return resolved;
    } catch (_) {
      // Widget tests and hosts with no stamped version.json.
    }
  }

  if (env.isNotEmpty) return env;
  return generated;
}

Future<({String version, String buildNumber})> _readPackageInfoVersion() async {
  final info = await PackageInfo.fromPlatform();
  return (version: info.version, buildNumber: info.buildNumber);
}

/// Version string the update checker can parse, or null when [version] and
/// [buildNumber] are placeholders (`0.0.0`, empty, build `0`).
///
/// An `alpha.N` / `Alpha-N` token in [version] wins over the build number.
/// Release tags such as `Alpha-18` are sometimes built with build number 1.
/// The `+N` build number is used only when the version name has no alpha
/// token (`1.0.0` + `18`, or `1.0.0+18`).
String? versionLabelFromPackageInfo({
  required String version,
  required String buildNumber,
}) {
  final versionReal = !_isPlaceholderVersion(version);
  final buildReal = _isUsableBuildNumber(buildNumber);
  if (!versionReal && !buildReal) return null;

  final n = alphaNumberFrom(
    version: versionReal ? version : '',
    buildNumber: buildReal ? buildNumber : null,
  );
  if (n == null) {
    return versionReal ? version.trim() : null;
  }

  final trimmed = version.trim();
  if (versionReal && parseAlphaNumber(trimmed) == n) {
    if (buildReal &&
        !trimmed.contains('+') &&
        int.tryParse(buildNumber.trim()) == n) {
      return '$trimmed+$n';
    }
    return trimmed;
  }
  return 'Alpha-$n';
}

/// N from `Alpha-N`, `1.0.0-alpha.N+N`, or a `+N` / [buildNumber] fallback.
int? alphaNumberFrom({required String version, String? buildNumber}) {
  final fromName = parseAlphaNumber(version);
  if (fromName != null) return fromName;
  if (buildNumber != null && _isUsableBuildNumber(buildNumber)) {
    return int.parse(buildNumber.trim());
  }
  final plus = RegExp(r'\+(\d+)\s*$').firstMatch(version.trim());
  if (plus == null) return null;
  final n = int.tryParse(plus.group(1)!);
  if (n == null || n <= 0) return null;
  return n;
}

/// `Alpha-N` when [version] encodes a release number, otherwise the raw text.
String alphaReleaseLabel(String version) {
  final n = alphaNumberFrom(version: version);
  if (n == null) {
    final trimmed = version.trim();
    return trimmed.isEmpty ? 'unknown' : trimmed;
  }
  return 'Alpha-$n';
}

/// Side-nav footer, e.g. `Mesh Utility Alpha-18`.
String meshUtilityFooterLabel(String version) =>
    'Mesh Utility ${alphaReleaseLabel(version)}';

/// Extract N from `Alpha-17`, `alpha-17`, `vAlpha-17`, or `1.0.0-alpha.17+17`.
int? parseAlphaNumber(String tagOrVersion) {
  final m = RegExp(
    r'alpha[^\d]*(\d+)',
    caseSensitive: false,
  ).firstMatch(tagOrVersion.trim());
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

bool _isPlaceholderVersion(String version) {
  final v = version.trim().toLowerCase();
  return v.isEmpty || v == '0.0.0' || v == '0.0.0.0' || v == 'unknown';
}

bool _isUsableBuildNumber(String buildNumber) {
  final n = int.tryParse(buildNumber.trim());
  return n != null && n > 0;
}
