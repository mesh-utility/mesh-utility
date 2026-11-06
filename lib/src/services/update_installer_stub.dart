import 'package:mesh_utility/src/services/update_check.dart';

Future<String?> installAndroidApk({
  required AppReleaseInfo release,
  void Function(String status)? onStatus,
}) async =>
    'Updates are not supported on this platform.';

Future<String?> installLinuxArchive({
  required AppReleaseInfo release,
  void Function(String status)? onStatus,
}) async =>
    'Updates are not supported on this platform.';
