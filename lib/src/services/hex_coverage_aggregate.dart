import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/off_ui.dart';
import 'package:mesh_utility/src/services/signal_class.dart';

/// Scale of the overview preload grid.
///
/// Detailed coverage hexes are never drawn at this size. They stay on the
/// stored scale-1 cell. Flat-to-flat width is the column spacing
/// `hexSize * sqrt(3) * lngScale * scale` degrees of longitude. At 40.7°N
/// (State College–Lewistown, central Pennsylvania) [distanceMiles] makes
/// scale 256 about 19.5 mi / 31.4 km wide.
const int mapHexMaxScale = 256;

/// Zoom where the overview layer hides when detailed coverage is in view.
///
/// Below this zoom the scale-256 preload stays up. It is not a paint size
/// for [CoverageZone] hexes.
const double mapHexMaxScaleZoom = 7.5;

/// Stored-cell scale. Map paint of coverage zones uses only this size.
const int mapTrueSizeScale = 1;

/// Heard filtered cells ÷ all filtered cells in the cluster.
///
/// The denominator is not the number of fine hexes that could fit in the
/// parent outline, and it is not a scan count. Unscanned fine hexes inside
/// the outline are omitted. The numerator is how many of the filtered child
/// cells heard a repeater (anything that is not a dead zone).
const String coverageFractionMeaning =
    'Heard cells divided by filtered cells in this cluster. '
    'Unscanned hexes inside the outline are not in the denominator.';

/// `heard/filtered heard (percent%)`, with both counts visible.
String formatCoverageFraction({
  required int heard,
  required int filteredChildren,
}) {
  if (filteredChildren <= 0) return '0/0 heard';
  final safeHeard = heard < 0
      ? 0
      : (heard > filteredChildren ? filteredChildren : heard);
  final percent = ((100 * safeHeard) / filteredChildren).round();
  return '$safeHeard/$filteredChildren heard ($percent%)';
}

/// Identity of a filtered zone list. Pan and zoom reuse the true-size cache
/// when this value is unchanged.
int coverageFilterIdentity(Iterable<CoverageZone> zones) {
  var hash = 0;
  var count = 0;
  for (final zone in zones) {
    count++;
    hash = Object.hash(
      hash,
      zone.id,
      zone.isDeadZone,
      zone.avgRssi,
      zone.avgSnr,
      zone.scanCount,
      zone.centerLat,
      zone.centerLng,
    );
  }
  return Object.hash(hash, count);
}

/// One parent hex (or one exact cell) and every filtered child assigned to it.
class HexCoverageCluster {
  const HexCoverageCluster({
    required this.scale,
    required this.row,
    required this.col,
    required this.centerLat,
    required this.centerLng,
    required this.points,
    required this.hitZoneId,
    required this.isDeadZone,
    required this.avgRssi,
    required this.avgSnr,
    required this.childCount,
    required this.coveredCount,
    required this.memberZoneIds,
  });

  final int scale;
  final int row;
  final int col;
  final double centerLat;
  final double centerLng;
  final List<LatLng> points;
  final String hitZoneId;
  final bool isDeadZone;
  final double? avgRssi;
  final double? avgSnr;
  final int childCount;

  /// Children that heard a repeater. Dead zones are the rest of [childCount].
  final int coveredCount;
  final List<String> memberZoneIds;
}

/// Groups [zones] into parent hexes of [scale].
///
/// Map paint calls this only at [mapTrueSizeScale]. That path keeps each
/// zone's stored polygon and does not merge. Larger scales remain for tests
/// and off-UI checks. Every finite zone is assigned to exactly one cluster.
/// The list order is the input order for scale 1, and parent row/column
/// order otherwise. This does not cull or drop children.
List<HexCoverageCluster> aggregateCoverageHexes(
  List<CoverageZone> zones, {
  required int scale,
}) {
  final safeScale = scale < 1 ? 1 : scale;
  if (safeScale == 1) {
    final exact = <HexCoverageCluster>[];
    for (final zone in zones) {
      if (!zone.centerLat.isFinite || !zone.centerLng.isFinite) continue;
      exact.add(_clusterFromZones(safeScale, <CoverageZone>[zone]));
    }
    return exact;
  }

  final groups = <String, List<CoverageZone>>{};
  final rows = <String, int>{};
  final cols = <String, int>{};
  for (final zone in zones) {
    if (!zone.centerLat.isFinite || !zone.centerLng.isFinite) continue;
    final cell = hexCellAt(zone.centerLat, zone.centerLng, scale: safeScale);
    final key = '${cell.row}:${cell.col}';
    groups.putIfAbsent(key, () => <CoverageZone>[]).add(zone);
    rows[key] = cell.row;
    cols[key] = cell.col;
  }
  final keys = groups.keys.toList()
    ..sort((a, b) {
      final byRow = rows[a]!.compareTo(rows[b]!);
      if (byRow != 0) return byRow;
      return cols[a]!.compareTo(cols[b]!);
    });
  return <HexCoverageCluster>[
    for (final key in keys) _clusterFromZones(safeScale, groups[key]!),
  ];
}

/// Isolate entry for [aggregateCoverageHexes]. Message keys: `zones`, `scale`.
List<HexCoverageCluster> aggregateCoverageHexesWorker(
  Map<String, Object?> message,
) {
  final scale = message['scale'];
  if (scale is! int) {
    throw ArgumentError.value(scale, 'scale', 'Expected an int hex scale');
  }
  return aggregateCoverageHexes(_zonesArg(message['zones']), scale: scale);
}

List<CoverageZone> _zonesArg(Object? raw) {
  if (raw is List<CoverageZone>) return raw;
  if (raw is List) return List<CoverageZone>.from(raw);
  throw ArgumentError.value(raw, 'zones', 'Expected a coverage zone list');
}

/// Same grouping as [aggregateCoverageHexes], off the UI isolate.
Future<List<HexCoverageCluster>> aggregateCoverageHexesOffUi(
  List<CoverageZone> zones, {
  required int scale,
}) {
  return runOffUi(
    aggregateCoverageHexesWorker,
    <String, Object?>{'zones': zones, 'scale': scale},
    force: true,
    weight: zones.length,
  );
}

HexCoverageCluster _clusterFromZones(int scale, List<CoverageZone> zones) {
  final best = _bestCoverageZone(zones);
  final cell = hexCellAt(best.centerLat, best.centerLng, scale: scale);
  var covered = 0;
  final members = <String>[];
  for (final zone in zones) {
    members.add(zone.id);
    if (!zone.isDeadZone) covered++;
  }
  final dead = covered == 0;
  final points = scale == 1
      ? zones.single.polygon
      : hexVertices(cell.lat, cell.lng, scale: scale);
  return HexCoverageCluster(
    scale: scale,
    row: cell.row,
    col: cell.col,
    centerLat: cell.lat,
    centerLng: cell.lng,
    points: points,
    hitZoneId: best.id,
    isDeadZone: dead,
    avgRssi: dead ? null : best.avgRssi,
    avgSnr: dead ? null : best.avgSnr,
    childCount: zones.length,
    coveredCount: covered,
    memberZoneIds: List<String>.unmodifiable(members),
  );
}

/// Most favorable child. A heard cell beats a dead cell. Among heard cells,
/// the higher signal level wins, then stronger RSSI, then stronger SNR.
CoverageZone _bestCoverageZone(List<CoverageZone> zones) {
  var best = zones.first;
  for (var i = 1; i < zones.length; i++) {
    if (_betterCoverage(zones[i], best)) best = zones[i];
  }
  return best;
}

bool _betterCoverage(CoverageZone candidate, CoverageZone current) {
  if (candidate.isDeadZone != current.isDeadZone) {
    return !candidate.isDeadZone;
  }
  if (!candidate.isDeadZone) {
    final candidateLevel = _heardLevel(candidate);
    final currentLevel = _heardLevel(current);
    if (candidateLevel != currentLevel) return candidateLevel > currentLevel;
    final rssiOrder = _compareOptionalHigh(candidate.avgRssi, current.avgRssi);
    if (rssiOrder != 0) return rssiOrder > 0;
    final snrOrder = _compareOptionalHigh(candidate.avgSnr, current.avgSnr);
    if (snrOrder != 0) return snrOrder > 0;
  }
  if (candidate.scanCount != current.scanCount) {
    return candidate.scanCount > current.scanCount;
  }
  if (candidate.lastScanned != current.lastScanned) {
    return candidate.lastScanned.isAfter(current.lastScanned);
  }
  return candidate.id.compareTo(current.id) < 0;
}

int _heardLevel(CoverageZone zone) {
  final level = signalLevelForValues(rssi: zone.avgRssi, snr: zone.avgSnr);
  return level < 1 ? 1 : level;
}

/// Positive when [candidate] is a stronger (less negative, or present) reading.
int _compareOptionalHigh(double? candidate, double? current) {
  if (candidate == null || !candidate.isFinite) {
    if (current == null || !current.isFinite) return 0;
    return -1;
  }
  if (current == null || !current.isFinite) return 1;
  return candidate.compareTo(current);
}
