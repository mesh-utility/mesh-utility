import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/grid.dart';

/// History-list filter. Top-level so [compute] can send it without a widget.
///
/// [params] keys: `scans` (`List<ScanResult>`), `selectedNodeIds`
/// (`List<String>`), `rangeStart` / `rangeEnd` (`DateTime`, both or neither),
/// `startHour` / `endHour` (`int`), `selectedHexId` (`String`).
List<ScanResult> filterHistoryScansOffUi(Map<String, Object?> params) {
  final scans = params['scans'] as List<ScanResult>;
  final selectedNodeIds =
      ((params['selectedNodeIds'] as List?) ?? const <dynamic>[])
          .cast<String>();
  final rangeStart = params['rangeStart'] as DateTime?;
  final rangeEnd = params['rangeEnd'] as DateTime?;
  final startHour = params['startHour'] as int?;
  final endHour = params['endHour'] as int?;
  final selectedHexId = params['selectedHexId'] as String?;
  final selectedNodeIdSet = selectedNodeIds.toSet();

  return scans.where((s) {
    if (selectedNodeIdSet.isNotEmpty && !selectedNodeIdSet.contains(s.nodeId)) {
      return false;
    }
    final localTs = s.timestamp.toLocal();
    if (rangeStart != null && rangeEnd != null) {
      final start = DateTime(rangeStart.year, rangeStart.month, rangeStart.day);
      final end = DateTime(
        rangeEnd.year,
        rangeEnd.month,
        rangeEnd.day,
        23,
        59,
        59,
        999,
      );
      if (localTs.isBefore(start) || localTs.isAfter(end)) {
        return false;
      }
    }
    if (startHour != null || endHour != null) {
      final hour = localTs.hour;
      final start = startHour ?? 0;
      final end = endHour ?? 23;
      final inRange = start <= end
          ? (hour >= start && hour <= end)
          : (hour >= start || hour <= end);
      if (!inRange) {
        return false;
      }
    }
    if (selectedHexId != null &&
        hexKey(s.latitude, s.longitude) != selectedHexId) {
      return false;
    }
    return true;
  }).toList();
}
