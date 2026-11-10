import 'dart:math' as math;

import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/radio_id_utils.dart';
import 'package:mesh_utility/src/services/signal_class.dart';

class HexDetailNode {
  const HexDetailNode({
    required this.id,
    this.name,
    this.role,
    this.senderName,
    this.receiverName,
    required this.lastTs,
    this.bestSnr,
    this.bestRssi,
    this.lastSnr,
    this.lastRssi,
    this.count = 1,
  });

  final String id;
  final String? name;
  final String? role;
  final String? senderName;
  final String? receiverName;
  final int lastTs;
  final double? bestSnr;
  final double? bestRssi;
  final double? lastSnr;
  final double? lastRssi;
  final int count;

  bool get isObserver => role == 'observer';
}

class HexDetail {
  const HexDetail({
    required this.row,
    required this.col,
    required this.scanCount,
    required this.lastTs,
    this.firstTs,
    this.bestSnr,
    this.bestRssi,
    this.lastSnr,
    this.lastRssi,
    this.altitude,
    this.lat,
    this.lng,
    this.lastNodeId,
    this.lastNodeName,
    this.nodes = const <HexDetailNode>[],
  });

  final int row;
  final int col;
  final int scanCount;
  final int lastTs;
  final int? firstTs;
  final double? bestSnr;
  final double? bestRssi;
  final double? lastSnr;
  final double? lastRssi;
  final double? altitude;
  final double? lat;
  final double? lng;
  final String? lastNodeId;
  final String? lastNodeName;
  final List<HexDetailNode> nodes;

  String get id => '$row:$col';
  String get zoneId => 'hex:$row:$col';
}

({int row, int col})? parseHexDetailId(String raw) {
  final trimmed = raw.trim();
  final id = trimmed.startsWith('hex:')
      ? trimmed.substring(4)
      : trimmed.startsWith('tile:')
      ? trimmed.substring(5)
      : trimmed;
  final parts = id.split(':');
  if (parts.length != 2) return null;
  final row = int.tryParse(parts[0]);
  final col = int.tryParse(parts[1]);
  if (row == null || col == null) return null;
  return (row: row, col: col);
}

double? _num(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  return double.tryParse(raw.toString());
}

int _int(Object? raw, [int fallback = 0]) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? fallback;
  return fallback;
}

List<HexDetailNode> _nodes(Object? raw) {
  if (raw is! List) return const <HexDetailNode>[];
  final out = <HexDetailNode>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = (entry['i'] ?? entry['id'] ?? entry['nodeId'])?.toString();
    if (id == null || id.isEmpty) continue;
    out.add(
      HexDetailNode(
        id: id,
        name: (entry['n'] ?? entry['name'])?.toString(),
        role: (entry['role'] ?? entry['type'])?.toString(),
        senderName: (entry['sn'] ?? entry['senderName'])?.toString(),
        receiverName: (entry['rn'] ??
                entry['receiverName'] ??
                entry['observerName'])
            ?.toString(),
        lastTs: _int(entry['t'] ?? entry['lastTs']),
        bestSnr: _num(entry['s'] ?? entry['snr'] ?? entry['bestSnr']),
        bestRssi: _num(entry['r'] ?? entry['rssi'] ?? entry['bestRssi']),
        lastSnr: _num(entry['ls'] ?? entry['lastSnr']),
        lastRssi: _num(entry['lr'] ?? entry['lastRssi']),
        count: _int(entry['c'] ?? entry['count'], 1),
      ),
    );
  }
  return out;
}

HexDetail? hexDetailFromListRow(List<Object?> entry) {
  if (entry.length < 13) return null;
  final row = _int(entry[0]);
  final col = _int(entry[1]);
  return HexDetail(
    row: row,
    col: col,
    scanCount: _int(entry[2]),
    lastTs: _int(entry[3]),
    bestSnr: _num(entry[4]),
    bestRssi: _num(entry[5]),
    lastSnr: _num(entry[6]),
    lastRssi: _num(entry[7]),
    altitude: _num(entry[8]),
    lat: _num(entry[9]),
    lng: _num(entry[10]),
    lastNodeId: entry[11]?.toString(),
    lastNodeName: entry[12]?.toString(),
    nodes: entry.length > 13 ? _nodes(entry[13]) : const <HexDetailNode>[],
  );
}

List<HexDetail> parseHexListPayload(Object? raw) {
  if (raw is! Map) return const <HexDetail>[];
  final rows = raw['h'];
  if (rows is! List) return const <HexDetail>[];
  final out = <HexDetail>[];
  for (final entry in rows) {
    if (entry is! List) continue;
    final parsed = hexDetailFromListRow(List<Object?>.from(entry));
    if (parsed != null) out.add(parsed);
  }
  return out;
}

HexDetail? parseHexDetailPayload(Object? raw) {
  if (raw is! Map) return null;
  final hex = raw['hex'];
  if (hex is! Map) return null;
  final parsed = parseHexDetailId(hex['id']?.toString() ?? '');
  final row = parsed?.row ?? (hex['row'] as num?)?.toInt();
  final col = parsed?.col ?? (hex['col'] as num?)?.toInt();
  if (row == null || col == null) return null;
  return HexDetail(
    row: row,
    col: col,
    scanCount: _int(hex['scanCount'] ?? hex['n']),
    lastTs: _int(hex['lastTs'] ?? hex['t']),
    firstTs: hex['firstTs'] == null ? null : _int(hex['firstTs']),
    bestSnr: _num(hex['bestSnr']),
    bestRssi: _num(hex['bestRssi']),
    lastSnr: _num(hex['lastSnr']),
    lastRssi: _num(hex['lastRssi']),
    altitude: _num(hex['altitude'] ?? hex['alt']),
    lat: _num(hex['lat']),
    lng: _num(hex['lng']),
    lastNodeId: hex['lastNodeId']?.toString(),
    lastNodeName: hex['lastNodeName']?.toString(),
    nodes: _nodes(hex['nodes']),
  );
}

/// Always the fixed grid center for [detail.row]/[detail.col]. Last-scan
/// lat/lng are never used for drawing or snapping.
({double lat, double lng}) hexDetailCenter(HexDetail detail) {
  return hexCellCenter(detail.row, detail.col);
}

String coverageZoneCellId(CoverageZone zone) {
  final parsed = parseHexDetailId(zone.id);
  if (parsed != null) return 'hex:${parsed.row}:${parsed.col}';
  final cell = hexCellAt(zone.centerLat, zone.centerLng);
  return 'hex:${cell.row}:${cell.col}';
}

/// Preferred zones first. Each grid cell is drawn once, at its true center.
List<CoverageZone> dedupeCoverageZonesByCell(
  Iterable<CoverageZone> preferred, [
  Iterable<CoverageZone> extra = const <CoverageZone>[],
]) {
  final seen = <String>{};
  final out = <CoverageZone>[];
  for (final zone in <CoverageZone>[...preferred, ...extra]) {
    if (seen.add(coverageZoneCellId(zone))) out.add(zone);
  }
  return out;
}

List<CoverageZone> coverageZonesFromHexDetails(Iterable<HexDetail> details) {
  final out = <CoverageZone>[];
  final seen = <String>{};
  for (final detail in details) {
    if (!seen.add(detail.zoneId)) continue;
    final center = hexDetailCenter(detail);
    final points = hexVertices(center.lat, center.lng);
    if (points.length < 3) continue;
    final rssi = detail.bestRssi ?? detail.lastRssi;
    final snr = detail.bestSnr ?? detail.lastSnr;
    final last = detail.lastTs > 0
        ? DateTime.fromMillisecondsSinceEpoch(detail.lastTs, isUtc: true)
        : DateTime.now().toUtc();
    out.add(
      CoverageZone(
        id: detail.zoneId,
        centerLat: center.lat,
        centerLng: center.lng,
        radiusMeters: 100,
        avgRssi: rssi,
        avgSnr: snr,
        scanCount: detail.scanCount,
        lastScanned: last,
        isDeadZone: deadZoneFromMetrics(avgRssi: rssi, avgSnr: snr),
        polygon: points,
      ),
    );
  }
  return out;
}


/// A node's own advertised/index name, never another node's lastNodeName.
String? _nameForHexNode(HexDetailNode node, HexDetail detail) {
  final own = (node.senderName ?? node.name)?.trim();
  if (own != null && own.isNotEmpty) return own;
  final nodeId = normalizeHexId(node.id);
  final lastId = normalizeHexId(detail.lastNodeId ?? '');
  if (nodeId.isNotEmpty && lastId.isNotEmpty && idsLikelySameDevice(nodeId, lastId)) {
    final lastName = (detail.lastNodeName ?? '').trim();
    return lastName.isEmpty ? null : lastName;
  }
  return null;
}

/// One synthetic scan per node (and last node if the list is empty) so History
/// and Nodes can fill from the same index without a raw-scan bulk download.
List<RawScan> rawScansFromHexDetails(Iterable<HexDetail> details) {
  final out = <RawScan>[];
  for (final detail in details) {
    final center = hexDetailCenter(detail);
    final nodes = detail.nodes;
    if (nodes.isEmpty) {
      out.add(
        RawScan(
          nodeId: detail.lastNodeId,
          latitude: center.lat,
          longitude: center.lng,
          rssi: detail.lastRssi ?? detail.bestRssi,
          snr: detail.lastSnr ?? detail.bestSnr,
          altitude: detail.altitude,
          timestamp: detail.lastTs > 0
              ? DateTime.fromMillisecondsSinceEpoch(detail.lastTs, isUtc: true)
              : null,
          senderName: detail.lastNodeName,
          downloadedFromWorker: true,
        ),
      );
      continue;
    }
    final observer = nodes.cast<HexDetailNode?>().firstWhere(
      (n) => n!.isObserver,
      orElse: () => null,
    );
    for (final node in nodes) {
      final when = node.lastTs > 0
          ? DateTime.fromMillisecondsSinceEpoch(node.lastTs, isUtc: true)
          : (detail.lastTs > 0
                ? DateTime.fromMillisecondsSinceEpoch(
                    detail.lastTs,
                    isUtc: true,
                  )
                : null);
      if (node.isObserver) {
        out.add(
          RawScan(
            observerId: node.id,
            radioId: node.id,
            nodeId: node.id,
            latitude: center.lat,
            longitude: center.lng,
            rssi: node.lastRssi ?? node.bestRssi,
            snr: node.lastSnr ?? node.bestSnr,
            altitude: detail.altitude,
            timestamp: when,
            receiverName: node.name ?? node.receiverName,
            downloadedFromWorker: true,
          ),
        );
        continue;
      }
      out.add(
        RawScan(
          observerId: observer?.id,
          radioId: observer?.id,
          nodeId: node.id,
          latitude: center.lat,
          longitude: center.lng,
          rssi: node.lastRssi ?? node.bestRssi ?? detail.lastRssi ?? detail.bestRssi,
          snr: node.lastSnr ?? node.bestSnr ?? detail.lastSnr ?? detail.bestSnr,
          altitude: detail.altitude,
          timestamp: when,
          senderName: _nameForHexNode(node, detail),
          receiverName: node.receiverName ?? observer?.name ?? observer?.receiverName,
          downloadedFromWorker: true,
        ),
      );
    }
  }
  return out;
}

/// Large viewports (zoomed-out Global) should use the world path.
bool shouldFetchHexWorld({
  required double south,
  required double north,
  required double west,
  required double east,
  bool cacheAreaIsGlobal = false,
}) {
  final latSpan = (north - south).abs();
  final lngSpan = (east - west).abs();
  if (cacheAreaIsGlobal && (latSpan >= 20 || lngSpan >= 20)) return true;
  return latSpan >= 40 || lngSpan >= 60;
}

({double south, double north, double west, double east}) radiusToBounds({
  required double lat,
  required double lng,
  required num radiusMiles,
}) {
  final latDelta = radiusMiles / 69.0;
  final cosLat = math.cos(lat * math.pi / 180.0).abs();
  final safeCos = cosLat < 0.15 ? 0.15 : cosLat;
  final lngDelta = radiusMiles / (69.0 * safeCos);
  return (
    south: lat - latDelta,
    north: lat + latDelta,
    west: lng - lngDelta,
    east: lng + lngDelta,
  );
}

/// Stable identity of one radio scan event (not one heard node).
String rawScanEventKey(RawScan scan) {
  final when = scan.timestamp ?? scan.receivedAt;
  final ts = when?.toUtc().millisecondsSinceEpoch ?? 0;
  final radio = (scan.radioId ?? scan.observerId ?? '').trim();
  return '$ts|$radio|${scan.latitude}|${scan.longitude}';
}

int _snrRank(RawScan scan) {
  final snr = scan.snr;
  if (snr == null) return -0x7fffffff;
  return (snr * 1000).round();
}

/// Collapses per-node NDJSON rows from `/scans/area` into one row per scan.
///
/// The kept row is the strongest heard node (highest SNR). Observer/receiver
/// name is taken from any row in the event that has one. Dead-zone scans
/// (empty node id) stay as a single row.
List<RawScan> groupRawScansByEvent(Iterable<RawScan> scans) {
  final best = <String, RawScan>{};
  final receiver = <String, String>{};
  for (final scan in scans) {
    final key = rawScanEventKey(scan);
    final name = scan.receiverName?.trim();
    if (name != null && name.isNotEmpty) {
      receiver[key] = name;
    }
    final existing = best[key];
    if (existing == null) {
      best[key] = scan;
      continue;
    }
    if (_snrRank(scan) > _snrRank(existing)) {
      best[key] = scan;
    }
  }
  final out = <RawScan>[];
  for (final entry in best.entries) {
    final scan = entry.value;
    final name = receiver[entry.key];
    if (name != null &&
        (scan.receiverName == null || scan.receiverName!.trim().isEmpty)) {
      out.add(
        RawScan(
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
          receiverName: name,
          radioId: scan.radioId,
          downloadedFromWorker: scan.downloadedFromWorker,
          locallyRecorded: scan.locallyRecorded,
        ),
      );
    } else {
      out.add(scan);
    }
  }
  out.sort((a, b) => b.effectiveTimestamp.compareTo(a.effectiveTimestamp));
  return out;
}

/// True when [lat]/[lng] snap to coverage cell ([row], [col]).
bool isScanInHexCell({
  required double lat,
  required double lng,
  required int row,
  required int col,
}) {
  final cell = hexCellAt(lat, lng);
  return cell.row == row && cell.col == col;
}

/// Scans that belong to [row]:[col], grouped to one row per real scan event.
List<RawScan> rawScansForHexCell({
  required Iterable<RawScan> scans,
  required int row,
  required int col,
}) {
  return groupRawScansByEvent([
    for (final scan in scans)
      if (isScanInHexCell(
        lat: scan.latitude,
        lng: scan.longitude,
        row: row,
        col: col,
      ))
        scan,
  ]);
}
