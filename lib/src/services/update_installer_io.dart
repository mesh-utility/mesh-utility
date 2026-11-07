import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/services/update_check.dart';
import 'package:path_provider/path_provider.dart';

const _updateChannel = MethodChannel('org.meshutility.app/updates');

const _unknownSourcesMessage =
    'Allow installing unknown apps for Mesh Utility, then try again.';

Future<String> _promptToAllowUnknownAppSources() async {
  try {
    await _updateChannel.invokeMethod<void>('openUnknownAppSourcesSettings');
  } catch (_) {}
  return _unknownSourcesMessage;
}

Future<String> _download(
  Uri url,
  File dest, {
  void Function(String)? onStatus,
}) async {
  onStatus?.call('Downloading…');
  final client = http.Client();
  try {
    final req = await client.send(http.Request('GET', url));
    if (req.statusCode != 200) {
      return 'Download failed (HTTP ${req.statusCode}).';
    }
    final sink = dest.openWrite();
    await req.stream.pipe(sink);
    await sink.close();
    return '';
  } finally {
    client.close();
  }
}

Future<String?> _verifySha256({
  required File file,
  required String? sumsUrl,
  required String assetName,
  void Function(String)? onStatus,
}) async {
  if (sumsUrl == null || sumsUrl.isEmpty) {
    return 'Missing SHA256SUMS.txt URL.';
  }
  onStatus?.call('Verifying checksum…');
  final resp = await http.get(Uri.parse(sumsUrl));
  if (resp.statusCode != 200) return 'Could not fetch SHA256SUMS.txt.';
  final expected = sha256ForAsset(resp.body, assetName);
  if (expected == null) return 'Asset not listed in SHA256SUMS.txt.';
  final digest = sha256.convert(await file.readAsBytes()).toString();
  if (digest.toLowerCase() != expected.toLowerCase()) {
    return 'Checksum mismatch.';
  }
  return null;
}

Future<String?> installAndroidApk({
  required AppReleaseInfo release,
  void Function(String status)? onStatus,
}) async {
  if (!Platform.isAndroid) return 'Android installer only.';
  final url = release.androidApkUrl;
  if (url == null || url.isEmpty) return 'No Android APK on this release.';
  final asset = androidApkAssetName(release.alphaNumber);

  try {
    final can = await _updateChannel.invokeMethod<bool>(
      'canRequestPackageInstalls',
    );
    if (can == false) {
      return await _promptToAllowUnknownAppSources();
    }
  } catch (_) {}

  final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
  await dir.create(recursive: true);
  final apk = File('${dir.path}/$asset');
  final err = await _download(Uri.parse(url), apk, onStatus: onStatus);
  if (err.isNotEmpty) return err;

  final verifyErr = await _verifySha256(
    file: apk,
    sumsUrl: release.sha256SumsUrl,
    assetName: asset,
    onStatus: onStatus,
  );
  if (verifyErr != null) return verifyErr;

  onStatus?.call('Launching installer…');
  try {
    await _updateChannel.invokeMethod('installApk', {'path': apk.path});
    return null;
  } on PlatformException catch (e) {
    if (e.code == 'unknown_sources') {
      return await _promptToAllowUnknownAppSources();
    }
    return 'Could not launch installer: $e';
  } catch (e) {
    return 'Could not launch installer: $e';
  }
}

Future<String?> installLinuxArchive({
  required AppReleaseInfo release,
  void Function(String status)? onStatus,
}) async {
  if (!Platform.isLinux) return 'Linux installer only.';
  final url = release.linuxArchiveUrl;
  if (url == null || url.isEmpty) return 'No Linux archive on this release.';
  final asset = linuxArchiveAssetName(release.alphaNumber);

  // Prefer the directory that contains the running binary (install tree).
  final exec = File(Platform.resolvedExecutable);
  final installDir = exec.parent;
  final staging = Directory('${installDir.path}.staging');
  final backup = Directory('${installDir.path}.bak');

  if (!await installDir.exists()) {
    return 'Install directory not found. See ${release.htmlUrl}';
  }

  // Writability probe
  try {
    final probe = File('${installDir.path}/.update_write_probe');
    await probe.writeAsString('ok');
    await probe.delete();
  } catch (_) {
    return 'Install directory is not writable (${installDir.path}). '
        'Download manually: ${release.htmlUrl}';
  }

  final tmp = await Directory.systemTemp.createTemp('mesh-utility-upd-');
  final archive = File('${tmp.path}/$asset');
  try {
    final err = await _download(Uri.parse(url), archive, onStatus: onStatus);
    if (err.isNotEmpty) return err;
    final verifyErr = await _verifySha256(
      file: archive,
      sumsUrl: release.sha256SumsUrl,
      assetName: asset,
      onStatus: onStatus,
    );
    if (verifyErr != null) return verifyErr;

    onStatus?.call('Extracting…');
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    final tar = await Process.run('tar', [
      '-xzf',
      archive.path,
      '-C',
      staging.path,
    ]);
    if (tar.exitCode != 0) {
      return 'Extract failed: ${tar.stderr}';
    }

    onStatus?.call('Swapping install…');
    if (await backup.exists()) {
      await backup.delete(recursive: true);
    }
    // Atomic-ish: move current -> .bak, staging -> current
    await installDir.rename(backup.path);
    try {
      await staging.rename(installDir.path);
    } catch (e) {
      // rollback
      if (await backup.exists()) {
        await backup.rename(installDir.path);
      }
      return 'Swap failed: $e. See ${release.htmlUrl}';
    }

    onStatus?.call('Relaunching…');
    final bin = File('${installDir.path}/mesh_utility');
    final launch = bin.existsSync() ? bin.path : Platform.resolvedExecutable;
    await Process.start(launch, const [], mode: ProcessStartMode.detached);
    // Give the new process a moment, then exit.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(0);
  } finally {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }
}
