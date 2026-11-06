import 'package:mesh_utility/src/services/update_check.dart';
import 'package:mesh_utility/src/services/update_installer_stub.dart'
    if (dart.library.io) 'package:mesh_utility/src/services/update_installer_io.dart'
    as impl;

Future<String?> installAndroidApk({
  required AppReleaseInfo release,
  void Function(String status)? onStatus,
}) =>
    impl.installAndroidApk(release: release, onStatus: onStatus);

Future<String?> installLinuxArchive({
  required AppReleaseInfo release,
  void Function(String status)? onStatus,
}) =>
    impl.installLinuxArchive(release: release, onStatus: onStatus);
