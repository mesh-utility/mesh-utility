import 'package:flutter/foundation.dart';

/// Side-nav index for the web-only Install page.
const int webInstallPageIndex = 8;

/// Label shown on the web-only Install / Downloads tab.
const String webInstallNavLabel = 'Install';

/// Key for the side-nav entry. Widget tests use this for presence and absence.
const Key webInstallNavKey = ValueKey<String>('web-install-nav');

/// Whether the Install / Downloads side-nav tab is shown.
///
/// Production calls this with no arguments so the tab follows [kIsWeb].
/// Widget tests pass [isWeb] because the test VM is not web, where [kIsWeb]
/// is always false.
bool webInstallNavVisible({bool? isWeb}) => isWeb ?? kIsWeb;
