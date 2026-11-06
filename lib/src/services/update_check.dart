import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/app_version.dart';
import 'package:mesh_utility/src/platform/local_contacts_supported.dart';

/// Parsed GitHub release used for in-app update checks.
class AppReleaseInfo {
  const AppReleaseInfo({
    required this.tagName,
    required this.name,
    required this.htmlUrl,
    required this.body,
    required this.alphaNumber,
    this.androidApkUrl,
    this.sha256SumsUrl,
    this.linuxArchiveUrl,
  });

  final String tagName;
  final String name;
  final String htmlUrl;
  final String body;
  final int alphaNumber;
  final String? androidApkUrl;
  final String? sha256SumsUrl;
  final String? linuxArchiveUrl;
}

/// True when [latestTag] is a newer Alpha-N than [currentVersion].
bool isNewerAlphaRelease({
  required String currentVersion,
  required String latestTag,
}) {
  final current = parseAlphaNumber(currentVersion);
  final latest = parseAlphaNumber(latestTag);
  if (current == null || latest == null) return false;
  return latest > current;
}

/// Fetches `/releases/latest` unauthenticated. Returns null on any failure.
Future<AppReleaseInfo?> fetchLatestRelease({
  http.Client? client,
  Uri? uri,
}) async {
  if (!localContactsSupported) return null;
  final httpClient = client ?? http.Client();
  final ownedClient = client == null;
  try {
    final url =
        uri ??
        Uri.parse(
          'https://api.github.com/repos/mesh-utility/mesh-utility/releases/latest',
        );
    final resp = await httpClient
        .get(
          url,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(resp.body);
    if (json is! Map) return null;
    final tag = (json['tag_name'] ?? '').toString();
    final alpha = parseAlphaNumber(tag);
    if (alpha == null) return null;
    String? apkUrl;
    String? sumsUrl;
    String? linuxUrl;
    final assets = json['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = (a['name'] ?? '').toString();
        final url = (a['browser_download_url'] ?? '').toString();
        if (name.endsWith('-android.apk') && name.startsWith('mesh-utility-')) {
          apkUrl = url;
        } else if (name.endsWith('-linux-x64.tar.gz') &&
            name.startsWith('mesh-utility-')) {
          linuxUrl = url;
        } else if (name == 'SHA256SUMS.txt') {
          sumsUrl = url;
        }
      }
    }
    return AppReleaseInfo(
      tagName: tag,
      name: (json['name'] ?? tag).toString(),
      htmlUrl: (json['html_url'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      alphaNumber: alpha,
      androidApkUrl: apkUrl,
      sha256SumsUrl: sumsUrl,
      linuxArchiveUrl: linuxUrl,
    );
  } catch (_) {
    return null;
  } finally {
    if (ownedClient) httpClient.close();
  }
}

/// Parse a SHA256SUMS.txt body for the checksum of [assetName].
String? sha256ForAsset(String sumsBody, String assetName) {
  for (final line in sumsBody.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final hash = parts[0].toLowerCase();
    final name = parts.sublist(1).join(' ');
    if (name == assetName || name.endsWith('/$assetName')) {
      return hash;
    }
  }
  return null;
}

/// Filename helpers for release assets (stable naming).
String androidApkAssetName(int alphaN) =>
    'mesh-utility-Alpha-$alphaN-android.apk';

String linuxArchiveAssetName(int alphaN) =>
    'mesh-utility-Alpha-$alphaN-linux-x64.tar.gz';
