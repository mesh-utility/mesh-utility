import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/radio_id_utils.dart';

List<CoverageZone> aggregateScansToZones(List<RawScan> scans) {
  final hexMap = <String, List<RawScan>>{};

  for (final scan in scans) {
    final key = hexKey(scan.latitude, scan.longitude);
    hexMap.putIfAbsent(key, () => <RawScan>[]).add(scan);
  }

  final zones = <CoverageZone>[];

  for (final entry in hexMap.entries) {
    final cellScans = entry.value;
    final snapped = snapToHexGrid(
      cellScans.first.latitude,
      cellScans.first.longitude,
    );

    final scansWithNodes = cellScans
        .where((s) => (s.nodeId?.isNotEmpty ?? false) && s.rssi != null)
        .toList();

    final isDeadZone = scansWithNodes.isEmpty;

    double? avgRssi;
    if (!isDeadZone) {
      avgRssi =
          scansWithNodes.map((s) => s.rssi!).reduce((a, b) => a + b) /
          scansWithNodes.length;
    }

    final snrScans = scansWithNodes.where((s) => s.snr != null).toList();
    double? avgSnr;
    if (!isDeadZone && snrScans.isNotEmpty) {
      avgSnr =
          snrScans.map((s) => s.snr!).reduce((a, b) => a + b) / snrScans.length;
    }

    final latestTimestamp = cellScans
        .map((s) => s.effectiveTimestamp)
        .reduce((a, b) => a.isAfter(b) ? a : b);

    zones.add(
      CoverageZone(
        id: entry.key,
        centerLat: snapped.snapLat,
        centerLng: snapped.snapLng,
        radiusMeters: 100,
        avgRssi: avgRssi,
        avgSnr: avgSnr,
        scanCount: cellScans.length,
        lastScanned: latestTimestamp,
        isDeadZone: isDeadZone,
        polygon: getHexVertices(snapped.snapLat, snapped.snapLng),
        radioId: cellScans.first.radioId,
      ),
    );
  }

  return zones;
}

String? _normalizedNodeName(String? name, String nodeId) {
  if (name == null || name.trim().isEmpty) return null;
  final trimmed = name.trim();
  if (trimmed == 'Unknown ($nodeId)') return null;
  if (trimmed.startsWith('Unknown (') && trimmed.endsWith(')')) return null;
  return trimmed;
}

List<MeshNode> extractNodes(List<RawScan> scans) {
  final nodeMap = <String, MeshNode>{};

  for (final scan in scans) {
    final nodeId = scan.nodeId;
    if (nodeId == null || nodeId.isEmpty) {
      continue;
    }
    if (_nodeIdIsObserverRadio(scan)) {
      continue;
    }

    final existing = nodeMap[nodeId];
    final ts = scan.effectiveTimestamp;
    final scanName = _normalizedNodeName(scan.senderName, nodeId);

    if (existing == null) {
      nodeMap[nodeId] = MeshNode(
        id: nodeId,
        nodeId: nodeId,
        name: scanName,
        hardwareType: null,
        lastSeen: ts,
        latitude: scan.latitude,
        longitude: scan.longitude,
      );
      continue;
    }

    final existingIsUnknown = existing.name?.startsWith('Unknown (') ?? false;
    final shouldUpdateName =
        scanName != null && (existingIsUnknown || existing.name == null);

    final updatedName = shouldUpdateName ? scanName : existing.name;
    final newerTimestamp = ts.isAfter(existing.lastSeen)
        ? ts
        : existing.lastSeen;

    nodeMap[nodeId] = MeshNode(
      id: existing.id,
      nodeId: nodeId,
      name: updatedName,
      hardwareType: existing.hardwareType,
      lastSeen: newerTimestamp,
      latitude: ts.isAfter(existing.lastSeen)
          ? scan.latitude
          : existing.latitude,
      longitude: ts.isAfter(existing.lastSeen)
          ? scan.longitude
          : existing.longitude,
    );
  }

  return nodeMap.values.toList();
}

List<ScanResult> convertToScanResults(List<RawScan> scans) {
  final results = <ScanResult>[];
  for (var i = 0; i < scans.length; i++) {
    final scan = scans[i];
    if ((scan.nodeId?.isEmpty ?? true) || scan.rssi == null) {
      continue;
    }

    results.add(
      ScanResult(
        id: 'scan-$i',
        observerId: scan.observerId ?? '',
        nodeId: scan.nodeId!,
        rssi: scan.rssi!,
        snr: scan.snr,
        snrIn: scan.snrIn,
        latitude: scan.latitude,
        longitude: scan.longitude,
        altitude: scan.altitude,
        timestamp: scan.effectiveTimestamp,
        senderName: _normalizedNodeName(scan.senderName, scan.nodeId!),
        receiverName: scan.receiverName,
        radioId: scan.radioId,
      ),
    );
  }
  return results;
}

/// Converts grouped hex-detail events for History, including deadzone rows
/// that [convertToScanResults] would drop (empty nodeId / null RSSI).
///
/// The popup "Scans" count and Cell history header both use this list so
/// they stay in agreement with unique scan events, not per-node NDJSON lines.
List<ScanResult> scanResultsForHexHistory(List<RawScan> scans) {
  final results = <ScanResult>[];
  for (var i = 0; i < scans.length; i++) {
    final scan = scans[i];
    final nodeId = scan.nodeId ?? '';
    results.add(
      ScanResult(
        id: 'hex-scan-$i',
        observerId: scan.observerId ?? '',
        nodeId: nodeId,
        rssi: scan.rssi ?? 0,
        snr: scan.snr,
        snrIn: scan.snrIn,
        latitude: scan.latitude,
        longitude: scan.longitude,
        altitude: scan.altitude,
        timestamp: scan.effectiveTimestamp,
        senderName: nodeId.isEmpty
            ? (scan.senderName ?? '')
            : _normalizedNodeName(scan.senderName, nodeId),
        receiverName: scan.receiverName,
        radioId: scan.radioId,
      ),
    );
  }
  return results;
}

/// True when this row's nodeId is the observing radio, not a heard mesh node.
bool _nodeIdIsObserverRadio(RawScan scan) {
  final nodeId = normalizeHexId(scan.nodeId ?? '');
  if (nodeId.isEmpty) return false;
  final observerId = normalizeHexId(scan.observerId ?? '');
  if (observerId.isNotEmpty && idsLikelySameDevice(nodeId, observerId)) {
    return true;
  }
  final radioId = normalizeHexId(scan.radioId ?? '');
  if (radioId.isNotEmpty && idsLikelySameDevice(nodeId, radioId)) {
    return true;
  }
  return false;
}
