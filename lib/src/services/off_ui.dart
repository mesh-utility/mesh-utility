import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// Scan-list size at which normalize, merge, and derived rebuilds leave the
/// UI isolate. Smaller lists stay inline so a single new scan does not pay
/// isolate startup.
const int heavyScanCount = 250;

/// Runs [worker] away from the platform UI isolate.
///
/// [worker] must be a top-level or static function. The closure passed to
/// [Isolate.run] is created in this function and closes over only [worker]
/// and [message]. A closure created in a method that also touches `this`
/// shares that method's context, and sending it copies the app state, the
/// widget tree, and other unsendable objects.
///
/// [message] and the value returned by [worker] must themselves be sendable
/// (lists, maps, primitives, typed data, or plain data objects of those).
/// Web has no background isolate, so the work stays on the caller there.
/// Heavy and forced calls use [Isolate.run] under tests as well; nothing
/// here checks `FLUTTER_TEST`.
Future<R> runOffUi<M, R>(
  R Function(M message) worker,
  M message, {
  bool force = false,
  int weight = 0,
}) {
  if (kIsWeb || (!force && weight < heavyScanCount)) {
    return Future<R>.sync(() => worker(message));
  }
  return Isolate.run(() => worker(message), debugName: 'mesh-off-ui');
}
