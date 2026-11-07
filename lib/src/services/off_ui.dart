import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// Scan-list size at which normalize, merge, and derived rebuilds leave the
/// UI isolate. Smaller lists stay inline so a single new scan does not pay
/// isolate startup.
const int heavyScanCount = 250;

/// Runs [computation] away from the platform UI isolate.
///
/// Web has no background isolate for this work, so the computation stays on
/// the caller there. Android is the target of the all-days ANR: parsing and
/// aggregating a full public history on the UI isolate blocks input for
/// minutes without an out-of-memory kill.
Future<T> runOffUi<T>(
  T Function() computation, {
  bool force = false,
  int weight = 0,
}) {
  if (kIsWeb || (!force && weight < heavyScanCount)) {
    return Future<T>.sync(computation);
  }
  return Isolate.run(computation);
}
