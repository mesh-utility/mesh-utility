import 'package:flutter/foundation.dart';

import 'package:mesh_utility/src/platform/local_contacts_supported_stub.dart'
    if (dart.library.io) 'package:mesh_utility/src/platform/local_contacts_supported_io.dart'
    as impl;

/// True when per-radio contact persistence + Contacts search are enabled.
bool get localContactsSupported => !kIsWeb && impl.localContactsSupported;
