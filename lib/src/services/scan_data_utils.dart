import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/radio_id_utils.dart';

/// Stable identity key for a [RawScan] — used for deduplication.
String scanIdentity(RawScan scan) {
  final sender = normalizeHexId(scan.nodeId ?? '');
  final observer = normalizeHexId(scan.observerId ?? '');
  final ts = scan.effectiveTimestamp.toUtc().millisecondsSinceEpoch;
  return '$sender|$observer|'
      '${scan.latitude.toStringAsFixed(6)}|${scan.longitude.toStringAsFixed(6)}|'
      '${scan.rssi?.toStringAsFixed(1) ?? 'na'}|$ts';
}

/// Returns true when [scan] has no node ID or no RSSI (dead/empty result).
bool isDeadLikeScan(RawScan scan) {
  final nodeId = (scan.nodeId ?? '').trim();
  return nodeId.isEmpty || scan.rssi == null;
}

/// Returns true when [scan] has a real node ID and RSSI.
bool isSuccessfulScan(RawScan scan) => !isDeadLikeScan(scan);

/// Returns a copy of [scan] with observer/node/radio IDs normalised via
/// [safePublicRadioId].
RawScan normalizeRawScanIds(RawScan scan) {
  return RawScan(
    observerId: safePublicRadioId(scan.observerId ?? ''),
    nodeId: safePublicRadioId(scan.nodeId ?? ''),
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
    radioId: safePublicRadioId(scan.radioId ?? ''),
    downloadedFromWorker: scan.downloadedFromWorker,
  );
}

/// Normalises every scan in [scans].
List<RawScan> normalizeRawScans(List<RawScan> scans) {
  return scans.map(normalizeRawScanIds).toList(growable: false);
}

/// Strips the `radioId` from dead-like rows in [scans] unless the row's radio
/// matches [connectedRadioId] (owner's own dead-zone reports are kept).
List<RawScan> sanitizeDeadzoneRadioIds(
  List<RawScan> scans,
  String? connectedRadioId,
) {
  final connected = safePublicRadioId(connectedRadioId ?? '');
  return scans
      .map((scan) {
        if (!isDeadLikeScan(scan)) return scan;
        final rowRadio = safePublicRadioId(scan.radioId ?? '');
        final keep =
            connected != null && rowRadio != null && connected == rowRadio;
        if (keep) return scan;
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
      })
      .toList(growable: false);
}

/// Strips the `radioId` from dead [zones] unless the zone's radio matches
/// [connectedRadioId].
List<CoverageZone> sanitizeDeadzoneZoneRadioIds(
  List<CoverageZone> zones,
  String? connectedRadioId,
) {
  final connected = safePublicRadioId(connectedRadioId ?? '');
  return zones
      .map((zone) {
        if (!zone.isDeadZone) return zone;
        final rowRadio = safePublicRadioId(zone.radioId ?? '');
        final keep =
            connected != null && rowRadio != null && connected == rowRadio;
        if (keep) return zone;
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
      })
      .toList(growable: false);
}
