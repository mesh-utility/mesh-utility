import 'dart:io';

/// Android and Linux only (not iOS/macOS/Windows for this feature).
bool get localContactsSupported =>
    Platform.isAndroid || Platform.isLinux;
