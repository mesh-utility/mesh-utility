import 'dart:convert';

import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/radio_id_utils.dart';
import 'package:mesh_utility/src/services/scan_aggregator.dart';
import 'package:mesh_utility/src/services/scan_data_utils.dart';

/// Storage key for the on-device raw scan cache.
const String rawScansStorageKey = 'scans:raw';

/// A history or deadzone window of 0 (or negative) means every available day.
bool isAllDaysWindow(int days) => days <= 0;

bool requestsAllDays({required int historyDays, required int deadzoneDays}) {
  return isAllDaysWindow(historyDays) || isAllDaysWindow(deadzoneDays);
}

/// Thrown when a history fetch should stop without applying a partial result.
class HistoryLoadCancelled implements Exception {
  const HistoryLoadCancelled();

  @override
  String toString() => 'History load cancelled';
}

class PreparedScans {
  const PreparedScans({
    required this.scans,
    required this.changed,
    required this.suppressedRows,
    required this.suppressedHexes,
  });

  final List<RawScan> scans;
  final bool changed;
  final int suppressedRows;
  final Set<String> suppressedHexes;
}

class PreparedZones {
  const PreparedZones({required this.zones, required this.suppressedRows});

  final List<CoverageZone> zones;
  final int suppressedRows;
}

class MergedScanHistory {
  const MergedScanHistory({
    required this.scans,
    required this.preservedLocal,
    required this.suppressedRows,
  });

  final List<RawScan> scans;
  final int preservedLocal;
  final int suppressedRows;
}

class DerivedScanData {
  const DerivedScanData({
    required this.zones,
    required this.nodes,
    required this.scanResults,
  });

  final List<CoverageZone> zones;
  final List<MeshNode> nodes;
  final List<ScanResult> scanResults;
}

class LoadedHistory {
  const LoadedHistory({
    required this.scans,
    required this.zones,
    required this.nodes,
    required this.scanResults,
    required this.persistedChanges,
    required this.suppressedRows,
  });

  static const empty = LoadedHistory(
    scans: <RawScan>[],
    zones: <CoverageZone>[],
    nodes: <MeshNode>[],
    scanResults: <ScanResult>[],
    persistedChanges: false,
    suppressedRows: 0,
  );

  final List<RawScan> scans;
  final List<CoverageZone> zones;
  final List<MeshNode> nodes;
  final List<ScanResult> scanResults;
  final bool persistedChanges;
  final int suppressedRows;
}

Map<String, dynamic> stringKeyMap(Map<dynamic, dynamic> raw) {
  return <String, dynamic>{
    for (final entry in raw.entries) entry.key.toString(): entry.value,
  };
}

/// Accepts the legacy decoded list and the compact JSON string written by
/// [encodeRawScansForStorage]. Every well-formed row is kept.
List<RawScan> decodeStoredRawScans(dynamic raw) {
  final rows = _storedRows(raw);
  if (rows.isEmpty) return const <RawScan>[];
  final scans = <RawScan>[];
  for (final row in rows) {
    if (row is Map<String, dynamic>) {
      scans.add(RawScan.fromJson(row));
    } else if (row is Map) {
      scans.add(RawScan.fromJson(stringKeyMap(row)));
    }
  }
  return scans;
}

List<dynamic> _storedRows(dynamic raw) {
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const <dynamic>[];
    final decoded = jsonDecode(trimmed);
    if (decoded is List) return decoded;
    return const <dynamic>[];
  }
  if (raw is List) return raw;
  return const <dynamic>[];
}

String encodeRawScansForStorage(List<RawScan> scans) {
  final compact = compactRawScansForPersistence(scans);
  return jsonEncode(
    compact.map((scan) => scan.toJson()).toList(growable: false),
  );
}

List<RawScan> compactRawScansForPersistence(List<RawScan> scans) {
  if (scans.isEmpty) return const <RawScan>[];

  final sorted = scans.toList(growable: false)
    ..sort((a, b) => b.effectiveTimestamp.compareTo(a.effectiveTimestamp));

  final seen = <String>{};
  final kept = <RawScan>[];
  for (final scan in sorted) {
    if (!seen.add(scanIdentity(scan))) continue;
    kept.add(scan);
  }
  return kept;
}

/// One pass over [scans]: optional deadzone radio sanitize, id normalize, and
/// deadzone-in-successful-hex suppression. Successful scans are never dropped.
PreparedScans prepareRawScans(
  List<RawScan> scans, {
  String? connectedRadioId,
  bool sanitizeDeadzoneRadios = false,
}) {
  if (scans.isEmpty) {
    return const PreparedScans(
      scans: <RawScan>[],
      changed: false,
      suppressedRows: 0,
      suppressedHexes: <String>{},
    );
  }

  final prepared = <RawScan>[];
  final successHexes = <String>{};
  var changed = false;
  for (final scan in scans) {
    final sanitized = sanitizeDeadzoneRadios
        ? _withSanitizedDeadzoneRadio(scan, connectedRadioId)
        : scan;
    final next = normalizeRawScanIds(sanitized);
    if (!identical(next, scan)) changed = true;
    if (isSuccessfulScan(next)) {
      successHexes.add(hexKey(next.latitude, next.longitude));
    }
    prepared.add(next);
  }
  if (successHexes.isEmpty) {
    return PreparedScans(
      scans: prepared,
      changed: changed,
      suppressedRows: 0,
      suppressedHexes: const <String>{},
    );
  }

  var write = 0;
  var suppressedRows = 0;
  final suppressedHexes = <String>{};
  for (var read = 0; read < prepared.length; read++) {
    final scan = prepared[read];
    final hex = hexKey(scan.latitude, scan.longitude);
    if (isDeadLikeScan(scan) && successHexes.contains(hex)) {
      suppressedRows += 1;
      suppressedHexes.add(hex);
      changed = true;
      continue;
    }
    prepared[write] = scan;
    write += 1;
  }
  final kept = write == prepared.length ? prepared : prepared.sublist(0, write);
  return PreparedScans(
    scans: kept,
    changed: changed,
    suppressedRows: suppressedRows,
    suppressedHexes: suppressedHexes,
  );
}

RawScan _withSanitizedDeadzoneRadio(RawScan scan, String? connectedRadioId) {
  if (!isDeadLikeScan(scan)) return scan;
  final connected = safePublicRadioId(connectedRadioId ?? '');
  final rowRadio = safePublicRadioId(scan.radioId ?? '');
  final keep = connected != null && rowRadio != null && connected == rowRadio;
  if (keep || scan.radioId == null) return scan;
  return RawScan(
    observerId: scan.observerId,
    nodeId: scan.nodeId,
    latitude: scan.latitude,
    longitude: scan.longitude,
    rssi: scan.rssi,
    snr: scan.snr,
    snrIn: scan.snrIn,
    altitude: scan.altitude,
    timestamp: scan.timestamp,
    receivedAt: scan.receivedAt,
    senderName: scan.senderName,
    receiverName: scan.receiverName,
    radioId: null,
    downloadedFromWorker: scan.downloadedFromWorker,
  );
}

PreparedZones prepareCoverageZones(
  List<CoverageZone> zones,
  String? connectedRadioId,
) {
  if (zones.isEmpty) {
    return const PreparedZones(zones: <CoverageZone>[], suppressedRows: 0);
  }
  final connected = safePublicRadioId(connectedRadioId ?? '');
  final successfulIds = <String>{};
  final sanitized = <CoverageZone>[];
  var changed = false;
  for (final zone in zones) {
    final next = _sanitizeZoneRadio(zone, connected);
    if (!identical(next, zone)) changed = true;
    if (!next.isDeadZone) successfulIds.add(next.id);
    sanitized.add(next);
  }
  if (successfulIds.isEmpty) {
    return PreparedZones(zones: changed ? sanitized : zones, suppressedRows: 0);
  }

  var suppressedRows = 0;
  final filtered = <CoverageZone>[];
  for (final zone in sanitized) {
    if (zone.isDeadZone && successfulIds.contains(zone.id)) {
      suppressedRows += 1;
      continue;
    }
    filtered.add(zone);
  }
  if (suppressedRows == 0 && !changed) {
    return PreparedZones(zones: zones, suppressedRows: 0);
  }
  return PreparedZones(
    zones: suppressedRows == 0 ? sanitized : filtered,
    suppressedRows: suppressedRows,
  );
}

CoverageZone _sanitizeZoneRadio(CoverageZone zone, String? connected) {
  if (!zone.isDeadZone) return zone;
  final rowRadio = safePublicRadioId(zone.radioId ?? '');
  final keep = connected != null && rowRadio != null && connected == rowRadio;
  if (keep || zone.radioId == null) return zone;
  return CoverageZone(
    id: zone.id,
    centerLat: zone.centerLat,
    centerLng: zone.centerLng,
    radiusMeters: zone.radiusMeters,
    avgRssi: zone.avgRssi,
    avgSnr: zone.avgSnr,
    scanCount: zone.scanCount,
    lastScanned: zone.lastScanned,
    isDeadZone: zone.isDeadZone,
    polygon: zone.polygon,
    radioId: null,
  );
}

/// Merges worker rows with local-only rows, then applies deadzone precedence
/// once. Worker rows win on identity. A local name replaces a placeholder
/// worker name. Successful scans from either side are kept.
MergedScanHistory mergeWorkerAndLocalScans({
  required List<RawScan> workerScans,
  required List<RawScan> localScans,
}) {
  final merged = <String, RawScan>{};
  for (final scan in workerScans) {
    merged[scanIdentity(scan)] = scan;
  }

  var preservedLocal = 0;
  for (final local in localScans) {
    final key = scanIdentity(local);
    final existing = merged[key];
    if (existing == null) {
      merged[key] = local;
      preservedLocal += 1;
      continue;
    }
    final workerName = (existing.senderName ?? '').trim();
    final localName = (local.senderName ?? '').trim();
    final workerIsPlaceholder =
        workerName.isEmpty ||
        isPlaceholderNodeName(workerName, existing.nodeId ?? '');
    final localIsPlaceholder =
        localName.isEmpty ||
        isPlaceholderNodeName(localName, local.nodeId ?? '');
    if (workerIsPlaceholder && !localIsPlaceholder) {
      merged[key] = existing.copyWith(senderName: localName);
    }
  }

  final prepared = prepareRawScans(merged.values.toList(growable: false));
  return MergedScanHistory(
    scans: prepared.scans,
    preservedLocal: preservedLocal,
    suppressedRows: prepared.suppressedRows,
  );
}

DerivedScanData buildDerivedScanData(
  List<RawScan> scans, {
  bool includeZones = true,
}) {
  final results = convertToScanResults(scans)
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return DerivedScanData(
    zones: includeZones ? aggregateScansToZones(scans) : const <CoverageZone>[],
    nodes: extractNodes(scans),
    scanResults: results,
  );
}

List<RawScan> parseRawScanBytes(
  List<int> bytes, {
  bool downloadedFromWorker = false,
}) {
  if (bytes.isEmpty) return const <RawScan>[];
  return parseRawScanPayload(
    utf8.decode(bytes, allowMalformed: true),
    downloadedFromWorker: downloadedFromWorker,
  );
}

List<RawScan> parseRawScanPayload(
  String payload, {
  bool downloadedFromWorker = false,
}) {
  final parsed = <RawScan>[];
  final trimmed = payload.trim();
  if (trimmed.isEmpty) return parsed;

  void addRow(Map<dynamic, dynamic> row) {
    final normalized = row is Map<String, dynamic> ? row : stringKeyMap(row);
    if (downloadedFromWorker && normalized['downloadedFromWorker'] != true) {
      normalized['downloadedFromWorker'] = true;
    }
    parsed.add(RawScan.fromJson(normalized));
  }

  if (trimmed.startsWith('[')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        for (final row in decoded) {
          if (row is Map) addRow(row);
        }
      }
    } catch (_) {
      return parsed;
    }
    return parsed;
  }

  final lines = const LineSplitter().convert(payload);
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) addRow(decoded);
    } catch (_) {
      // Skip malformed rows instead of failing the day.
    }
  }
  return parsed;
}

/// Returns null when the payload is JSON but not a zone list, so a static
/// file can fall through to the dynamic coverage API.
List<CoverageZone>? parseCoverageZoneBytes(List<int> bytes) {
  if (bytes.isEmpty) return const <CoverageZone>[];
  final trimmed = utf8.decode(bytes, allowMalformed: true).trim();
  if (trimmed.isEmpty) return const <CoverageZone>[];
  final decoded = jsonDecode(trimmed);
  if (decoded is! List) return null;
  final zones = <CoverageZone>[];
  for (final row in decoded) {
    if (row is Map<String, dynamic>) {
      zones.add(CoverageZone.fromJson(row));
    } else if (row is Map) {
      zones.add(CoverageZone.fromJson(stringKeyMap(row)));
    }
  }
  return zones;
}
