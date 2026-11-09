import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/off_ui.dart';
import 'package:mesh_utility/src/services/signal_class.dart';

/// Exact base cells are drawn at and above this zoom.
///
/// Below it, coverage is drawn as parent hexes of [mapHexZoomBands]. The
/// threshold is the zoom where a base cell is about 48px wide, so a phone
/// or a 1024×768 tablet view of solid coverage stays under the polygon cap.
const double mapDetailZoom = 15.5;

/// Largest parent hex the coverage map draws.
///
/// Flat-to-flat width is the column spacing
/// `hexSize * sqrt(3) * lngScale * scale` degrees of longitude. At 40.7°N
/// (State College–Lewistown, central Pennsylvania) [distanceMiles] makes
/// scale 256 about 19.5 mi / 31.4 km wide. Scale 128 is about 9.8 mi /
/// 15.7 km, under the 15–20 mi stop. Scale 512 is about 39 mi / 63 km,
/// past it. 256 is the power-of-two parent in that range.
const int mapHexMaxScale = 256;

/// Zoom where [mapHexMaxScale] starts. Lower zooms keep that parent, so the
/// cell only renders smaller.
const double mapHexMaxScaleZoom = 7.5;

/// One zoom band. [minZoom] is inclusive; the next higher band wins above it.
class HexZoomBand {
  const HexZoomBand(this.minZoom, this.scale);

  final double minZoom;

  /// Linear parent size. 1 is the stored cell. 2, 4, 8, … are coarser hexes
  /// on the same odd-row grid.
  final int scale;
}

/// High zoom is exact. Each step down doubles the parent hex so a cluster
/// stays on the order of 48–96px wide (column spacing) on a web-mercator map.
///
/// Doubling stops at [mapHexMaxScale]. [hexClusterScaleForZoom] uses the last
/// band for every zoom below [mapHexMaxScaleZoom].
const List<HexZoomBand> mapHexZoomBands = <HexZoomBand>[
  HexZoomBand(mapDetailZoom, 1),
  HexZoomBand(14.5, 2),
  HexZoomBand(13.5, 4),
  HexZoomBand(12.5, 8),
  HexZoomBand(11.5, 16),
  HexZoomBand(10.5, 32),
  HexZoomBand(9.5, 64),
  HexZoomBand(8.5, 128),
  HexZoomBand(mapHexMaxScaleZoom, mapHexMaxScale),
];

/// Parent scales the map and the settings slider share, finest first.
///
/// [mapHexMaxScale] stays the hard ceiling. A stored max may pick any step
/// at or below it.
const List<int> mapHexScaleSteps = <int>[
  1,
  2,
  4,
  8,
  16,
  32,
  64,
  128,
  mapHexMaxScale,
];

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

/// Parent scale for [zoom].
///
/// [maxScale] is a tighter ceiling than [mapHexMaxScale]. The result is the
/// band scale, or that ceiling when the band is coarser. Null keeps the hard
/// ceiling only.
int hexClusterScaleForZoom(double zoom, {int? maxScale}) {
  final z = zoom.isFinite ? zoom : 0;
  var scale = _cappedHexScale(mapHexZoomBands.last.scale);
  for (final band in mapHexZoomBands) {
    if (z >= band.minZoom) {
      scale = _cappedHexScale(band.scale);
      break;
    }
  }
  final ceiling = clampMaxHexScale(maxScale);
  return scale > ceiling ? ceiling : scale;
}

/// Next coarser parent, or null at the ceiling.
///
/// The ceiling is [maxScale] when set, otherwise [mapHexMaxScale]. The
/// 700-polygon backstop uses this, so an over-full view cannot grow past
/// the user's max or the central-Pennsylvania cell.
int? coarserHexScale(int scale, {int? maxScale}) {
  final ceiling = clampMaxHexScale(maxScale);
  if (scale >= ceiling) return null;
  final doubled = scale < 1 ? 1 : scale * 2;
  if (doubled > ceiling) return null;
  return doubled;
}

int _cappedHexScale(int scale) {
  if (scale < 1) return 1;
  if (scale > mapHexMaxScale) return mapHexMaxScale;
  return scale;
}

/// Nearest [mapHexScaleSteps] entry.
///
/// Null keeps [mapHexMaxScale] so an older settings file stays on today's
/// cap. A tie lands on the coarser step. Values outside the list land on
/// the nearer end.
int clampMaxHexScale(int? value) {
  if (value == null) return mapHexMaxScale;
  var best = mapHexScaleSteps.first;
  var bestDistance = (value - best).abs();
  for (var i = 1; i < mapHexScaleSteps.length; i++) {
    final step = mapHexScaleSteps[i];
    final distance = (value - step).abs();
    if (distance <= bestDistance) {
      best = step;
      bestDistance = distance;
    }
  }
  return best;
}

/// Flat-to-flat miles at ~40.7°N for one parent of [scale].
double hexScaleWidthMiles(int scale) {
  final safe = scale < 1 ? 1 : scale;
  const lat = 40.7;
  const lng = -77.7;
  return distanceMiles(lat, lng, lat, lng + colSpacing * safe);
}

/// Slider text for one allowed parent scale.
///
/// Scale 1 names the stored cell. Every other step is the rounded
/// flat-to-flat width in miles.
String hexScaleMilesLabel(int scale) {
  final safe = clampMaxHexScale(scale);
  final miles = hexScaleWidthMiles(safe);
  final text = miles >= 0.25
      ? miles.toStringAsFixed(1)
      : miles.toStringAsFixed(2);
  if (safe == 1) return 'Actual cells (~$text mi)';
  return '~$text mi';
}

/// Identity of a filtered zone list. Pan and zoom reuse a cache entry when
/// this value and the hex scale are unchanged.
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
/// Every finite zone is assigned to exactly one cluster. [scale] 1 keeps each
/// zone's own polygon. The list order is the input order for scale 1, and
/// parent row/column order otherwise. This does not cull or drop children.
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
