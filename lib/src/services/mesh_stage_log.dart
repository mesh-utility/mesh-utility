import 'package:flutter/foundation.dart';

/// One privacy-safe line for the Android log.
///
/// Release builds drop info logs from [AppDebugLogService], and [debugPrint]
/// can hold lines until the UI isolate is idle. Completion of an all-days
/// load has to show up while that isolate is still busy, so this writes
/// straight through. Counts and durations only: no names, messages,
/// coordinates, or ids.
void meshStage(
  String stage, {
  required String event,
  int? count,
  int? ms,
  int? n2,
}) {
  final buffer = StringBuffer('mesh-stage stage=')
    ..write(stage)
    ..write(' event=')
    ..write(event);
  if (count != null) {
    buffer
      ..write(' count=')
      ..write(count);
  }
  if (ms != null) {
    buffer
      ..write(' ms=')
      ..write(ms);
  }
  if (n2 != null) {
    buffer
      ..write(' n2=')
      ..write(n2);
  }
  debugPrintSynchronously(buffer.toString());
}

void meshStageStart(String stage, {int? count, int? n2}) {
  meshStage(stage, event: 'start', count: count, n2: n2);
}

void meshStageEnd(String stage, {int? count, int? ms, int? n2}) {
  meshStage(stage, event: 'end', count: count, ms: ms, n2: n2);
}
