import 'dart:convert';
import 'dart:math' as math;

import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/grid.dart';

/// Downloaded-scan cache keeps everything inside the chosen area.
const String scanCacheModeRadius = 'radius';

/// First-level divisions (states, provinces, prefectures).
const String scanCacheModeAdmin1 = 'admin1';

/// Second-level divisions. This build ships US counties only.
const String scanCacheModeAdmin2 = 'admin2';

/// No geographic prune.
const String scanCacheModeGlobal = 'global';

const int defaultScanCacheRadiusMiles = 50;

const List<int> scanCacheRadiusMileChoices = <int>[
  10,
  25,
  50,
  100,
  250,
  500,
  800,
];

const double kmPerMile = 1.609344;

const String scanCacheStorageNote =
    'A larger area, more selections, or Global uses more storage and can slow startup.';

const String scanCacheCountyNote =
    'Counties cover the United States only. Other countries are not included.';

/// Shown under the cache-area control. The same choice limits the worker fetch.
const String scanCacheCloudNote =
    'This also limits cloud downloads. States, counties, and areas larger than 250 miles are sent as map bounds. An older server still returns at most 250 miles around a point. This device then keeps only the area you selected.';

/// `worker/src/index.ts` `parseRadiusMiles` uses `Math.min(parsed, 250)`.
/// Requests above this still prune locally to the real cache area.
const int workerScanRadiusCapMiles = 250;


bool isScanCacheMode(String mode) {
  return mode == scanCacheModeRadius ||
      mode == scanCacheModeAdmin1 ||
      mode == scanCacheModeAdmin2 ||
      mode == scanCacheModeGlobal;
}

int clampScanCacheRadiusMiles(int value) {
  if (scanCacheRadiusMileChoices.contains(value)) return value;
  return defaultScanCacheRadiusMiles;
}

String clampScanCacheMode(String? value) {
  if (value != null && isScanCacheMode(value)) return value;
  return scanCacheModeRadius;
}

/// Own recordings stay in the cache in every mode.
///
/// A scan recorded on this device is [RawScan.locallyRecorded]. Scans that
/// have not been marked downloaded are treated the same way so older rows
/// saved before that flag existed are kept.
bool scanKeptInAnyCacheArea(RawScan scan) {
  return scan.locallyRecorded || !scan.downloadedFromWorker;
}

/// Stamp device-recorded rows so a later upload, which sets
/// [RawScan.downloadedFromWorker], does not make them eligible to prune.
List<RawScan> stampLocallyRecorded(List<RawScan> scans) {
  var changed = false;
  final next = List<RawScan>.generate(scans.length, (index) {
    final scan = scans[index];
    if (scan.downloadedFromWorker || scan.locallyRecorded) return scan;
    changed = true;
    return scan.copyWith(locallyRecorded: true);
  }, growable: false);
  return changed ? next : scans;
}

bool sameScanCacheArea({
  required String previousMode,
  required String nextMode,
  required int previousRadiusMiles,
  required int nextRadiusMiles,
  required List<String> previousAdmin1Ids,
  required List<String> nextAdmin1Ids,
  required List<String> previousAdmin2Ids,
  required List<String> nextAdmin2Ids,
}) {
  return previousMode == nextMode &&
      previousRadiusMiles == nextRadiusMiles &&
      _sameIds(previousAdmin1Ids, nextAdmin1Ids) &&
      _sameIds(previousAdmin2Ids, nextAdmin2Ids);
}

bool _sameIds(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  final left = a.toSet();
  if (left.length != b.toSet().length) return false;
  for (final id in b) {
    if (!left.contains(id)) return false;
  }
  return true;
}

/// True when the next area can include scans the previous area would drop.
///
/// A pure shrink (smaller radius, or a subset of the same divisions) is not
/// an expansion. Global to a bounded mode is a shrink. Any other mode change
/// refetches, because the areas are not nested.
bool scanCacheAreaExpands({
  required String previousMode,
  required String nextMode,
  required int previousRadiusMiles,
  required int nextRadiusMiles,
  required List<String> previousAdmin1Ids,
  required List<String> nextAdmin1Ids,
  required List<String> previousAdmin2Ids,
  required List<String> nextAdmin2Ids,
}) {
  if (previousMode != nextMode) {
    if (nextMode == scanCacheModeGlobal) return true;
    if (previousMode == scanCacheModeGlobal) return false;
    return true;
  }
  switch (nextMode) {
    case scanCacheModeRadius:
      return nextRadiusMiles > previousRadiusMiles;
    case scanCacheModeAdmin1:
      return !_isSuperset(previousAdmin1Ids, nextAdmin1Ids);
    case scanCacheModeAdmin2:
      return !_isSuperset(previousAdmin2Ids, nextAdmin2Ids);
    default:
      return false;
  }
}

bool _isSuperset(List<String> previous, List<String> next) {
  final have = previous.toSet();
  for (final id in next) {
    if (!have.contains(id)) return false;
  }
  return true;
}

/// Radius mode keeps every downloaded scan until a center exists.
bool scanCacheWillFilter({
  required String mode,
  required double? centerLat,
  required double? centerLng,
}) {
  switch (mode) {
    case scanCacheModeGlobal:
      return false;
    case scanCacheModeRadius:
      return centerLat != null && centerLng != null;
    case scanCacheModeAdmin1:
    case scanCacheModeAdmin2:
      return true;
    default:
      return false;
  }
}

/// Re-prune a radius cache after the device moves far enough that the circle
/// no longer covers the same hexes. The first known fix always qualifies.
bool scanCacheFixShouldReprune({
  required String mode,
  required int radiusMiles,
  required double? previousLat,
  required double? previousLng,
  required double lat,
  required double lng,
}) {
  if (mode != scanCacheModeRadius) return false;
  if (previousLat == null || previousLng == null) return true;
  final shift = distanceMiles(previousLat, previousLng, lat, lng);
  final threshold = math.max(5.0, radiusMiles * 0.1);
  return shift >= threshold;
}

class ScanCachePruneResult {
  const ScanCachePruneResult({
    required this.scans,
    required this.dropped,
    required this.hexMembershipTests,
    required this.hexMembership,
  });

  final List<RawScan> scans;
  final int dropped;

  /// Point-in-polygon or radius evaluations. Scans that share a hex reuse one.
  final int hexMembershipTests;
  final Map<String, bool> hexMembership;
}

/// Keeps local scans and downloaded scans whose hex center is inside the area.
///
/// [polygonsById] maps a selected division id to polygons. Each polygon is a
/// list of rings, and each ring is a list of `[lng, lat]` points. The first
/// ring is the outer boundary. Later rings are holes.
///
/// Radius checks compare kilometers (`miles * 1.609344`) against the hex
/// center. The setting itself stores the discrete mile choice.
ScanCachePruneResult pruneScansToCacheArea({
  required List<RawScan> scans,
  required String mode,
  required int radiusMiles,
  double? centerLat,
  double? centerLng,
  Set<String> selectedIds = const <String>{},
  Map<String, List<List<List<List<double>>>>> polygonsById =
      const <String, List<List<List<List<double>>>>>{},
  Map<String, bool> priorMembership = const <String, bool>{},
}) {
  final normalized = clampScanCacheMode(mode);
  if (!scanCacheWillFilter(
    mode: normalized,
    centerLat: centerLat,
    centerLng: centerLng,
  )) {
    return ScanCachePruneResult(
      scans: scans,
      dropped: 0,
      hexMembershipTests: 0,
      hexMembership: Map<String, bool>.from(priorMembership),
    );
  }

  final prepared = _prepareDivisions(
    normalized == scanCacheModeRadius ? const <String>{} : selectedIds,
    polygonsById,
  );
  final membership = Map<String, bool>.from(priorMembership);
  var tests = 0;
  var dropped = 0;
  final kept = <RawScan>[];
  for (final scan in scans) {
    if (scanKeptInAnyCacheArea(scan)) {
      kept.add(scan);
      continue;
    }
    final cell = snapToHexGrid(scan.latitude, scan.longitude);
    final hex = hexKey(scan.latitude, scan.longitude);
    var inside = membership[hex];
    if (inside == null) {
      tests += 1;
      inside = _hexInside(
        mode: normalized,
        hexLat: cell.snapLat,
        hexLng: cell.snapLng,
        radiusMiles: radiusMiles,
        centerLat: centerLat,
        centerLng: centerLng,
        divisions: prepared,
      );
      membership[hex] = inside;
    }
    if (inside) {
      kept.add(scan);
    } else {
      dropped += 1;
    }
  }
  return ScanCachePruneResult(
    scans: dropped == 0 ? scans : List<RawScan>.unmodifiable(kept),
    dropped: dropped,
    hexMembershipTests: tests,
    hexMembership: membership,
  );
}

bool _hexInside({
  required String mode,
  required double hexLat,
  required double hexLng,
  required int radiusMiles,
  required double? centerLat,
  required double? centerLng,
  required List<_PreparedDivision> divisions,
}) {
  if (mode == scanCacheModeRadius) {
    if (centerLat == null || centerLng == null) return true;
    final limitKm = radiusMiles * kmPerMile;
    final distanceKm =
        distanceMiles(hexLat, hexLng, centerLat, centerLng) * kmPerMile;
    return distanceKm <= limitKm;
  }
  for (final division in divisions) {
    if (division.contains(hexLng, hexLat)) return true;
  }
  return false;
}

class _PreparedDivision {
  _PreparedDivision(this.polygons)
    : minLng = _minLng(polygons),
      minLat = _minLat(polygons),
      maxLng = _maxLng(polygons),
      maxLat = _maxLat(polygons);

  final List<List<List<List<double>>>> polygons;
  final double minLng;
  final double minLat;
  final double maxLng;
  final double maxLat;

  bool contains(double lng, double lat) {
    if (lng < minLng || lng > maxLng || lat < minLat || lat > maxLat) {
      return false;
    }
    for (final polygon in polygons) {
      if (polygon.isEmpty || polygon.first.length < 3) continue;
      if (!_pointInRing(lng, lat, polygon.first)) continue;
      var inHole = false;
      for (var ring = 1; ring < polygon.length; ring++) {
        if (_pointInRing(lng, lat, polygon[ring])) {
          inHole = true;
          break;
        }
      }
      if (!inHole) return true;
    }
    return false;
  }
}

double _minLng(List<List<List<List<double>>>> polygons) {
  var value = double.infinity;
  for (final polygon in polygons) {
    for (final ring in polygon) {
      for (final point in ring) {
        if (point.length < 2) continue;
        if (point[0] < value) value = point[0];
      }
    }
  }
  return value;
}

double _maxLng(List<List<List<List<double>>>> polygons) {
  var value = -double.infinity;
  for (final polygon in polygons) {
    for (final ring in polygon) {
      for (final point in ring) {
        if (point.length < 2) continue;
        if (point[0] > value) value = point[0];
      }
    }
  }
  return value;
}

double _minLat(List<List<List<List<double>>>> polygons) {
  var value = double.infinity;
  for (final polygon in polygons) {
    for (final ring in polygon) {
      for (final point in ring) {
        if (point.length < 2) continue;
        if (point[1] < value) value = point[1];
      }
    }
  }
  return value;
}

double _maxLat(List<List<List<List<double>>>> polygons) {
  var value = -double.infinity;
  for (final polygon in polygons) {
    for (final ring in polygon) {
      for (final point in ring) {
        if (point.length < 2) continue;
        if (point[1] > value) value = point[1];
      }
    }
  }
  return value;
}

List<_PreparedDivision> _prepareDivisions(
  Set<String> selectedIds,
  Map<String, List<List<List<List<double>>>>> polygonsById,
) {
  if (selectedIds.isEmpty || polygonsById.isEmpty) return const [];
  final prepared = <_PreparedDivision>[];
  for (final id in selectedIds) {
    final polygons = polygonsById[id];
    if (polygons == null || polygons.isEmpty) continue;
    prepared.add(_PreparedDivision(polygons));
  }
  return prepared;
}

bool _pointInRing(double lng, double lat, List<List<double>> ring) {
  var inside = false;
  var j = ring.length - 1;
  for (var i = 0; i < ring.length; i++) {
    final point = ring[i];
    final previous = ring[j];
    if (point.length < 2 || previous.length < 2) {
      j = i;
      continue;
    }
    final xi = point[0];
    final yi = point[1];
    final xj = previous[0];
    final yj = previous[1];
    final crosses = (yi > lat) != (yj > lat);
    if (crosses) {
      final denom = yj - yi;
      if (denom != 0) {
        final xCross = (xj - xi) * (lat - yi) / denom + xi;
        if (lng < xCross) inside = !inside;
      }
    }
    j = i;
  }
  return inside;
}

/// Decode one generated geometry file.
///
/// The file is `{"s": scale, "d": {key: [[[ring, ...hole], ...polygon]]}}`.
/// Rings are delta-encoded integer coordinates. [country] is the file prefix
/// and becomes the part of the division id before `:`.
void decodeScanCacheGeometry({
  required String country,
  required String jsonText,
  required Set<String> fullIds,
  required Map<String, List<List<List<List<double>>>>> into,
}) {
  if (fullIds.isEmpty) return;
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map) return;
  final scale = (decoded['s'] as num?)?.toInt() ?? 100;
  final divisions = decoded['d'];
  if (divisions is! Map) return;
  final wanted = <String, String>{};
  for (final id in fullIds) {
    final colon = id.indexOf(':');
    if (colon <= 0) continue;
    if (id.substring(0, colon) != country) continue;
    wanted[id.substring(colon + 1)] = id;
  }
  if (wanted.isEmpty) return;
  for (final entry in divisions.entries) {
    final fullId = wanted[entry.key.toString()];
    if (fullId == null) continue;
    final polygons = _decodePolygons(entry.value, scale);
    if (polygons.isEmpty) continue;
    into[fullId] = polygons;
  }
}

List<List<List<List<double>>>> _decodePolygons(Object? raw, int scale) {
  if (raw is! List) return const [];
  final polygons = <List<List<List<double>>>>[];
  for (final polygon in raw) {
    if (polygon is! List) continue;
    final rings = <List<List<double>>>[];
    for (final ring in polygon) {
      if (ring is! String || ring.isEmpty) continue;
      final decoded = decodeDeltaRing(ring, scale);
      if (decoded.length >= 3) rings.add(decoded);
    }
    if (rings.isNotEmpty) polygons.add(rings);
  }
  return polygons;
}

/// First token is an absolute scaled coordinate. Later tokens are deltas.
List<List<double>> decodeDeltaRing(String encoded, int scale) {
  if (scale == 0) return const [];
  final points = <List<double>>[];
  var lng = 0;
  var lat = 0;
  var first = true;
  final scaleDouble = scale.toDouble();
  for (final token in encoded.split(' ')) {
    if (token.isEmpty) continue;
    final comma = token.indexOf(',');
    if (comma <= 0) continue;
    final x = int.tryParse(token.substring(0, comma));
    final y = int.tryParse(token.substring(comma + 1));
    if (x == null || y == null) continue;
    if (first) {
      lng = x;
      lat = y;
      first = false;
    } else {
      lng += x;
      lat += y;
    }
    points.add(<double>[lng / scaleDouble, lat / scaleDouble]);
  }
  return points;
}

Map<String, Set<String>> groupScanCacheIds(Iterable<String> ids) {
  final grouped = <String, Set<String>>{};
  for (final id in ids) {
    final colon = id.indexOf(':');
    if (colon <= 0 || colon >= id.length - 1) continue;
    grouped.putIfAbsent(id.substring(0, colon), () => <String>{}).add(id);
  }
  return grouped;
}

int ceilScanCacheRadiusMiles(int miles) {
  for (final choice in scanCacheRadiusMileChoices) {
    if (choice >= miles) return choice;
  }
  return scanCacheRadiusMileChoices.last;
}

/// Pre-scan-cache settings stored only `syncRadiusMiles`. `0` was worldwide.
({String mode, int radiusMiles}) scanCacheFromLegacySyncRadius(
  int syncRadiusMiles,
) {
  if (syncRadiusMiles <= 0) {
    return (
      mode: scanCacheModeGlobal,
      radiusMiles: defaultScanCacheRadiusMiles,
    );
  }
  return (
    mode: scanCacheModeRadius,
    radiusMiles: ceilScanCacheRadiusMiles(syncRadiusMiles),
  );
}

bool settingsJsonHasScanCache(Map<String, dynamic> json) {
  return json.containsKey('scanCacheMode') ||
      json.containsKey('scanCacheRadiusMiles') ||
      json.containsKey('scanCacheAdmin1Ids') ||
      json.containsKey('scanCacheAdmin2Ids');
}

/// Value written back to `syncRadiusMiles` for one release. Old builds only
/// understand 0, 10, 25, 50, 100, and 250. Global is 0. Any other cache mode
/// writes the stored radius choice capped at the worker maximum.
int legacySyncRadiusMilesForReaders({
  required String mode,
  required int scanCacheRadiusMiles,
}) {
  if (mode == scanCacheModeGlobal) return 0;
  final capped = scanCacheRadiusMiles > workerScanRadiusCapMiles
      ? workerScanRadiusCapMiles
      : scanCacheRadiusMiles;
  const allowed = <int>{0, 10, 25, 50, 100, 250};
  if (allowed.contains(capped)) return capped;
  return 0;
}

/// Union of division outlines. Null when nothing was selected or loaded.
class DivisionBbox {
  const DivisionBbox({
    required this.minLatitude,
    required this.minLongitude,
    required this.maxLatitude,
    required this.maxLongitude,
  });

  final double minLatitude;
  final double minLongitude;
  final double maxLatitude;
  final double maxLongitude;

  bool get isValid =>
      minLatitude.isFinite &&
      maxLatitude.isFinite &&
      minLatitude <= maxLatitude &&
      minLongitude <= maxLongitude;
}

DivisionBbox? bboxOfPolygons(
  Map<String, List<List<List<List<double>>>>> polygonsById,
) {
  var minLat = double.infinity;
  var minLng = double.infinity;
  var maxLat = -double.infinity;
  var maxLng = -double.infinity;
  var any = false;
  for (final polygons in polygonsById.values) {
    for (final polygon in polygons) {
      for (final ring in polygon) {
        for (final point in ring) {
          if (point.length < 2) continue;
          any = true;
          if (point[0] < minLng) minLng = point[0];
          if (point[0] > maxLng) maxLng = point[0];
          if (point[1] < minLat) minLat = point[1];
          if (point[1] > maxLat) maxLat = point[1];
        }
      }
    }
  }
  if (!any) return null;
  return DivisionBbox(
    minLatitude: minLat,
    minLongitude: minLng,
    maxLatitude: maxLat,
    maxLongitude: maxLng,
  );
}

/// What to pass to [WorkerApi.fetchRawScans] / coverage.
///
/// [skip] means do not call the worker for this area (empty division list, or
/// a radius with no device fix). A null [radiusMiles] omits lat/lng/radius,
/// which is today's worldwide fetch. The radius is the intended miles. The
/// worker still clamps [radiusMiles] to [workerScanRadiusCapMiles]. When the
/// area is wider than that cap, or the mode is a division union, [minLatitude]
/// and the other edges are set too. A new worker uses the box. An older worker
/// ignores those keys and uses the radius around [latitude]/[longitude].
/// For a division union that point is the device or last-known fix when that
/// fix lies inside the box, otherwise the box center. The radius still reaches
/// the far corner of the box from that point. Local prune uses the real cache
/// area either way.
class CloudFetchQuery {
  const CloudFetchQuery({
    required this.skip,
    this.latitude,
    this.longitude,
    this.radiusMiles,
    this.minLatitude,
    this.maxLatitude,
    this.minLongitude,
    this.maxLongitude,
  });

  final bool skip;
  final double? latitude;
  final double? longitude;
  final int? radiusMiles;
  final double? minLatitude;
  final double? maxLatitude;
  final double? minLongitude;
  final double? maxLongitude;

  static const skipped = CloudFetchQuery(skip: true);

  static const worldwide = CloudFetchQuery(skip: false);

  bool get omitsRadius => !skip && (radiusMiles == null || radiusMiles! <= 0);

  bool get hasBounds =>
      minLatitude != null &&
      maxLatitude != null &&
      minLongitude != null &&
      maxLongitude != null;
}

CloudFetchQuery cloudQueryForCache({
  required String mode,
  required int radiusMiles,
  required double? centerLat,
  required double? centerLng,
  DivisionBbox? divisionBbox,
}) {
  switch (clampScanCacheMode(mode)) {
    case scanCacheModeGlobal:
      return CloudFetchQuery.worldwide;
    case scanCacheModeRadius:
      if (centerLat == null || centerLng == null) {
        return CloudFetchQuery.skipped;
      }
      final miles = clampScanCacheRadiusMiles(radiusMiles);
      final query = CloudFetchQuery(
        skip: false,
        latitude: centerLat,
        longitude: centerLng,
        radiusMiles: miles,
      );
      if (miles <= workerScanRadiusCapMiles) return query;
      final box = boundsForRadiusMiles(
        latitude: centerLat,
        longitude: centerLng,
        radiusMiles: miles,
      );
      return CloudFetchQuery(
        skip: false,
        latitude: centerLat,
        longitude: centerLng,
        radiusMiles: miles,
        minLatitude: box.minLatitude,
        maxLatitude: box.maxLatitude,
        minLongitude: box.minLongitude,
        maxLongitude: box.maxLongitude,
      );
    case scanCacheModeAdmin1:
    case scanCacheModeAdmin2:
      final bbox = divisionBbox;
      if (bbox == null || !bbox.isValid) return CloudFetchQuery.skipped;
      return _queryAroundBbox(bbox, deviceLat: centerLat, deviceLng: centerLng);
    default:
      return CloudFetchQuery.skipped;
  }
}

/// Circle box using the worker's degree formula, without the 250 mile clamp.
///
/// `latDelta = miles / 69` and `lngDelta = miles / (69 * max(|cos(lat)|, 0.1))`.
/// Latitude is clamped to [-90, 90]. A longitude past ±180 is returned with
/// [minLongitude] greater than [maxLongitude], which is the antimeridian split.
({
  double minLatitude,
  double maxLatitude,
  double minLongitude,
  double maxLongitude,
})
boundsForRadiusMiles({
  required double latitude,
  required double longitude,
  required int radiusMiles,
}) {
  final latDelta = radiusMiles / 69.0;
  final cosLat = math.cos(latitude * math.pi / 180.0);
  final safeCos = math.max(cosLat.abs(), 0.1);
  final lngDelta = radiusMiles / (69.0 * safeCos);
  var minLatitude = latitude - latDelta;
  var maxLatitude = latitude + latDelta;
  if (minLatitude < -90) minLatitude = -90;
  if (maxLatitude > 90) maxLatitude = 90;
  var minLongitude = longitude - lngDelta;
  var maxLongitude = longitude + lngDelta;
  if (minLongitude < -180) minLongitude += 360;
  if (maxLongitude > 180) maxLongitude -= 360;
  return (
    minLatitude: minLatitude,
    maxLatitude: maxLatitude,
    minLongitude: minLongitude,
    maxLongitude: maxLongitude,
  );
}

bool _bboxCoversWholeGlobe(DivisionBbox bbox) {
  final latSpan = bbox.maxLatitude - bbox.minLatitude;
  final lngSpan = bbox.minLongitude <= bbox.maxLongitude
      ? bbox.maxLongitude - bbox.minLongitude
      : (180 - bbox.minLongitude) + (bbox.maxLongitude + 180);
  return latSpan >= 179 && lngSpan >= 359;
}

bool _deviceInsideBbox(double latitude, double longitude, DivisionBbox bbox) {
  if (latitude < bbox.minLatitude || latitude > bbox.maxLatitude) return false;
  if (bbox.minLongitude <= bbox.maxLongitude) {
    return longitude >= bbox.minLongitude && longitude <= bbox.maxLongitude;
  }
  return longitude >= bbox.minLongitude || longitude <= bbox.maxLongitude;
}

CloudFetchQuery _queryAroundBbox(
  DivisionBbox bbox, {
  double? deviceLat,
  double? deviceLng,
}) {
  if (_bboxCoversWholeGlobe(bbox)) return CloudFetchQuery.worldwide;
  // Old servers ignore the box and clamp the radius at 250 miles around this
  // point. A device inside the selection keeps that circle on the device.
  final double latitude;
  final double longitude;
  if (deviceLat != null &&
      deviceLng != null &&
      deviceLat.isFinite &&
      deviceLng.isFinite &&
      _deviceInsideBbox(deviceLat, deviceLng, bbox)) {
    latitude = deviceLat;
    longitude = deviceLng;
  } else {
    latitude = (bbox.minLatitude + bbox.maxLatitude) / 2;
    longitude = (bbox.minLongitude + bbox.maxLongitude) / 2;
  }
  final corners = <List<double>>[
    <double>[bbox.minLatitude, bbox.minLongitude],
    <double>[bbox.minLatitude, bbox.maxLongitude],
    <double>[bbox.maxLatitude, bbox.minLongitude],
    <double>[bbox.maxLatitude, bbox.maxLongitude],
  ];
  var farthest = 0.0;
  for (final corner in corners) {
    final miles = distanceMiles(latitude, longitude, corner[0], corner[1]);
    if (miles > farthest) farthest = miles;
  }
  // One extra mile covers the worker's 69 miles-per-degree box versus haversine.
  var radius = farthest.ceil() + 1;
  if (radius < 1) radius = 1;
  return CloudFetchQuery(
    skip: false,
    latitude: latitude,
    longitude: longitude,
    radiusMiles: radius,
    minLatitude: bbox.minLatitude,
    maxLatitude: bbox.maxLatitude,
    minLongitude: bbox.minLongitude,
    maxLongitude: bbox.maxLongitude,
  );
}

/// True when [deviceLat]/[deviceLng] is outside a radius cache centered on
/// [centerLat]/[centerLng]. No center means the device is not treated as
/// outside (there is no disk to leave).
bool deviceOutsideRadiusCache({
  required double deviceLat,
  required double deviceLng,
  required double? centerLat,
  required double? centerLng,
  required int radiusMiles,
}) {
  if (centerLat == null || centerLng == null) return false;
  return distanceMiles(deviceLat, deviceLng, centerLat, centerLng) >
      radiusMiles;
}

bool pointInsideSelectedDivisions({
  required double latitude,
  required double longitude,
  required Set<String> selectedIds,
  required Map<String, List<List<List<List<double>>>>> polygonsById,
}) {
  if (selectedIds.isEmpty || polygonsById.isEmpty) return false;
  return _hexInside(
    mode: scanCacheModeAdmin1,
    hexLat: latitude,
    hexLng: longitude,
    radiusMiles: 0,
    centerLat: null,
    centerLng: null,
    divisions: _prepareDivisions(selectedIds, polygonsById),
  );
}

Map<String, List<List<List<List<double>>>>> polygonsFromGeometryMessage(
  Map<String, Object?> message,
) {
  final polygons = <String, List<List<List<List<double>>>>>{};
  final selected = <String>{
    ...((message['selectedIds'] as List?) ?? const <Object>[])
        .whereType<String>(),
  };
  final geometry = message['geometry'];
  if (geometry is List) {
    for (final entry in geometry) {
      if (entry is! Map) continue;
      final country = entry['country']?.toString() ?? '';
      final jsonText = entry['json']?.toString() ?? '';
      if (country.isEmpty || jsonText.isEmpty) continue;
      decodeScanCacheGeometry(
        country: country,
        jsonText: jsonText,
        fullIds: selected,
        into: polygons,
      );
    }
  }
  return polygons;
}

/// Isolate entry. Message keys: `scans`, `mode`, `radiusMiles`, `centerLat`,
/// `centerLng`, `selectedIds`, `geometry` (`[{country, json}]`), `membership`.
ScanCachePruneResult pruneScanCacheWorker(Map<String, Object?> message) {
  final polygons = polygonsFromGeometryMessage(message);
  final selected = <String>{
    ...((message['selectedIds'] as List?) ?? const <Object>[])
        .whereType<String>(),
  };
  final priorRaw = message['membership'];
  final prior = <String, bool>{};
  if (priorRaw is Map) {
    for (final entry in priorRaw.entries) {
      if (entry.key is String && entry.value is bool) {
        prior[entry.key as String] = entry.value as bool;
      }
    }
  }
  final scansRaw = message['scans'];
  final scans = scansRaw is List<RawScan>
      ? scansRaw
      : scansRaw is List
      ? List<RawScan>.from(scansRaw)
      : const <RawScan>[];
  return pruneScansToCacheArea(
    scans: scans,
    mode: message['mode']?.toString() ?? scanCacheModeRadius,
    radiusMiles:
        (message['radiusMiles'] as num?)?.toInt() ??
        defaultScanCacheRadiusMiles,
    centerLat: (message['centerLat'] as num?)?.toDouble(),
    centerLng: (message['centerLng'] as num?)?.toDouble(),
    selectedIds: selected,
    polygonsById: polygons,
    priorMembership: prior,
  );
}

/// Isolate entry. Returns min/max lat/lng, or null when no ring was decoded.
Map<String, double>? bboxFromGeometryWorker(Map<String, Object?> message) {
  final bbox = bboxOfPolygons(polygonsFromGeometryMessage(message));
  if (bbox == null) return null;
  return <String, double>{
    'minLat': bbox.minLatitude,
    'minLng': bbox.minLongitude,
    'maxLat': bbox.maxLatitude,
    'maxLng': bbox.maxLongitude,
  };
}

/// Isolate entry. True when the point is inside a selected division.
bool pointInsideGeometryWorker(Map<String, Object?> message) {
  final lat = (message['lat'] as num?)?.toDouble();
  final lng = (message['lng'] as num?)?.toDouble();
  if (lat == null || lng == null) return false;
  final selected = <String>{
    ...((message['selectedIds'] as List?) ?? const <Object>[])
        .whereType<String>(),
  };
  return pointInsideSelectedDivisions(
    latitude: lat,
    longitude: lng,
    selectedIds: selected,
    polygonsById: polygonsFromGeometryMessage(message),
  );
}

/// Heavy `jsonDecode` for a boundary index. The caller interprets the map.
Object? parseBoundaryIndexWorker(String raw) {
  return jsonDecode(raw);
}

String scanCacheMembershipSignature({
  required String mode,
  required int radiusMiles,
  required double? centerLat,
  required double? centerLng,
  required List<String> admin1Ids,
  required List<String> admin2Ids,
}) {
  final center = centerLat == null || centerLng == null
      ? 'none'
      : '${(centerLat * 1000).round()}:${(centerLng * 1000).round()}';
  final admin1 = admin1Ids.toList(growable: false)..sort();
  final admin2 = admin2Ids.toList(growable: false)..sort();
  return '$mode|$radiusMiles|$center|${admin1.join(",")}|${admin2.join(",")}';
}
