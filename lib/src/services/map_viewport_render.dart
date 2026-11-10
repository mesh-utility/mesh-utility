import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/hex_coverage_aggregate.dart';

export 'package:mesh_utility/src/services/hex_coverage_aggregate.dart'
    show
        HexCoverageCluster,
        aggregateCoverageHexes,
        aggregateCoverageHexesOffUi,
        coverageFilterIdentity,
        coverageFractionMeaning,
        formatCoverageFraction,
        mapHexMaxScale,
        mapHexMaxScaleZoom,
        mapTrueSizeScale;

/// Extra fraction of the camera kept on each edge so hexes do not pop
/// while the view is still moving.
const double mapViewportMarginFraction = 0.15;

/// Debug hint only. A view with at least this many true-size hexes is heavy
/// until raster tiles exist. Every hex that intersects the viewport is still
/// drawn. This is not a cap.
const int mapHeavyTrueSizeDrawCount = 4000;

/// Quiet period before a pan or zoom recomputes the visible set.
const Duration mapViewportDebounce = Duration(milliseconds: 100);

/// Longest a continuous pan can go without a viewport refresh.
const Duration mapViewportMaxWait = Duration(milliseconds: 220);

/// How long to wait before the next viewport pass.
///
/// Each camera event resets a [mapViewportDebounce] timer. Once the burst
/// has already lasted [mapViewportMaxWait], the delay is zero so the set
/// still refreshes during a long pan.
Duration mapViewportRefreshDelay({
  required Duration sinceBurst,
  Duration debounce = mapViewportDebounce,
  Duration maxWait = mapViewportMaxWait,
}) {
  if (sinceBurst <= Duration.zero) return debounce;
  if (sinceBurst >= maxWait) return Duration.zero;
  final untilMax = maxWait - sinceBurst;
  return untilMax < debounce ? untilMax : debounce;
}

/// Camera window in degrees. Longitude may cross the antimeridian.
class MapRenderViewport {
  const MapRenderViewport.exact({
    required this.south,
    required this.north,
    required this.west,
    required this.east,
    required this.crossesAntimeridian,
    required this.spansAllLongitudes,
    required this.zoom,
    required this.longitudeCenter,
    required this.longitudeWidth,
  });

  /// Pads [south]/[north]/[longitudeWidth] by [mapViewportMarginFraction]
  /// and by one hex so a cell under the finger is not culled.
  factory MapRenderViewport.fromCenterWidth({
    required double south,
    required double north,
    required double longitudeCenter,
    required double longitudeWidth,
    required double zoom,
    double marginFraction = mapViewportMarginFraction,
  }) {
    if (!south.isFinite ||
        !north.isFinite ||
        !longitudeCenter.isFinite ||
        !longitudeWidth.isFinite) {
      return MapRenderViewport.exact(
        south: -90,
        north: 90,
        west: -180,
        east: 180,
        crossesAntimeridian: false,
        spansAllLongitudes: true,
        zoom: zoom.isFinite ? zoom : 0,
        longitudeCenter: 0,
        longitudeWidth: 360,
      );
    }

    var latSouth = math.min(south, north);
    var latNorth = math.max(south, north);
    final latSpan = latNorth - latSouth;
    final latPad = math.max(latSpan * marginFraction, hexSize);
    latSouth = math.max(-90, latSouth - latPad);
    latNorth = math.min(90, latNorth + latPad);

    final center = _wrapLongitude(longitudeCenter);
    final width = longitudeWidth.abs();
    final lngPad = math.max(width * marginFraction, hexSize * lngScale);
    final paddedWidth = width + lngPad * 2;
    if (paddedWidth >= 360) {
      return MapRenderViewport.exact(
        south: latSouth,
        north: latNorth,
        west: -180,
        east: 180,
        crossesAntimeridian: false,
        spansAllLongitudes: true,
        zoom: zoom,
        longitudeCenter: center,
        longitudeWidth: 360,
      );
    }

    final rawWest = center - paddedWidth / 2;
    final rawEast = center + paddedWidth / 2;
    final crosses = rawWest < -180 || rawEast > 180;
    if (!crosses) {
      return MapRenderViewport.exact(
        south: latSouth,
        north: latNorth,
        west: rawWest,
        east: rawEast,
        crossesAntimeridian: false,
        spansAllLongitudes: false,
        zoom: zoom,
        longitudeCenter: center,
        longitudeWidth: paddedWidth,
      );
    }

    return MapRenderViewport.exact(
      south: latSouth,
      north: latNorth,
      west: _wrapLongitude(rawWest),
      east: _wrapLongitude(rawEast),
      crossesAntimeridian: true,
      spansAllLongitudes: false,
      zoom: zoom,
      longitudeCenter: center,
      longitudeWidth: paddedWidth,
    );
  }

  final double south;
  final double north;
  final double west;
  final double east;
  final bool crossesAntimeridian;
  final bool spansAllLongitudes;
  final double zoom;
  final double longitudeCenter;
  final double longitudeWidth;

  bool containsLatLng(double latitude, double longitude) {
    if (!latitude.isFinite || !longitude.isFinite) return false;
    if (latitude < south || latitude > north) return false;
    if (spansAllLongitudes) return true;
    return _longitudeInRange(
      longitude,
      west: west,
      east: east,
      crossesAntimeridian: crossesAntimeridian,
    );
  }
}

/// One polygon to paint. [hitZoneId] is always a zone from the input list
/// so a tap still opens that zone's scans.
class MapDrawPolygon {
  const MapDrawPolygon({
    required this.hitZoneId,
    required this.points,
    required this.isDeadZone,
    required this.avgRssi,
    required this.avgSnr,
    this.childCount = 1,
    this.coveredCount = 0,
    this.scale = 1,
    this.memberZoneIds = const <String>[],
  });

  final String hitZoneId;
  final List<LatLng> points;
  final bool isDeadZone;
  final double? avgRssi;
  final double? avgSnr;

  /// Filtered child cells represented by this polygon.
  final int childCount;

  /// Child cells that heard a repeater. See [coverageFractionMeaning].
  final int coveredCount;

  /// 1 is an exact stored cell. Larger values are parent hexes.
  final int scale;
  final List<String> memberZoneIds;

  bool containsZone(String zoneId) {
    if (hitZoneId == zoneId) return true;
    for (final id in memberZoneIds) {
      if (id == zoneId) return true;
    }
    return false;
  }
}

/// True-size polygons for one camera.
///
/// [scale] is always [mapTrueSizeScale]. Nothing is merged or dropped to
/// keep a count down.
class MapRenderPlan {
  const MapRenderPlan({required this.polygons, this.scale = mapTrueSizeScale});

  final List<MapDrawPolygon> polygons;

  /// Hex scale actually drawn. Always the stored cell.
  final int scale;

  int get representedChildren {
    var sum = 0;
    for (final polygon in polygons) {
      sum += polygon.childCount;
    }
    return sum;
  }
}

/// A resolved draw, or the parent scale that still needs to be aggregated.
sealed class MapRenderAttempt {}

class MapRenderReady extends MapRenderAttempt {
  MapRenderReady(this.plan);

  final MapRenderPlan plan;
}

class MapRenderNeedsScale extends MapRenderAttempt {
  MapRenderNeedsScale(this.scale);

  final int scale;
}

/// Zones to paint for [viewport].
///
/// The input list is not modified. Stats and filters stay on that full
/// selection; this only chooses what the layer draws. Pass an already
/// filtered list. Every finite zone whose stored hex intersects the viewport
/// is drawn at [mapTrueSizeScale]. Zoom does not resize, merge, or drop hexes.
List<MapDrawPolygon> selectZonesForMapRender({
  required List<CoverageZone> zones,
  required MapRenderViewport viewport,
}) {
  return planZonesForMapRender(zones: zones, viewport: viewport).polygons;
}

/// Full render decision. The drawn scale is always the stored cell.
MapRenderPlan planZonesForMapRender({
  required List<CoverageZone> zones,
  required MapRenderViewport viewport,
  Map<int, List<HexCoverageCluster>>? clustersByScale,
}) {
  final attempt = resolveMapRender(
    zones: zones,
    viewport: viewport,
    allowCompute: true,
    lookup: (scale) => clustersByScale?[scale],
  );
  if (attempt is! MapRenderReady) {
    throw StateError('Map render did not resolve a polygon set.');
  }
  return attempt.plan;
}

MapRenderAttempt resolveMapRender({
  required List<CoverageZone> zones,
  required MapRenderViewport viewport,
  required List<HexCoverageCluster>? Function(int scale) lookup,
  bool allowCompute = false,
}) {
  const scale = mapTrueSizeScale;
  final found = lookup(scale);
  if (found == null && !allowCompute) {
    return MapRenderNeedsScale(scale);
  }
  final clusters = found ?? aggregateCoverageHexes(zones, scale: scale);
  final polygons = <MapDrawPolygon>[
    for (final cluster in clusters)
      if (cluster.points.length >= 3 &&
          _clusterIntersectsViewport(cluster, viewport))
        _polygonForCluster(cluster),
  ];
  return MapRenderReady(MapRenderPlan(polygons: polygons, scale: scale));
}

/// Cached parent-hex aggregates for one filtered dataset.
///
/// Pan and zoom inside a scale only cull. A new filter identity drops the
/// cache and ignores aggregates that were already running.
class HexRenderSession {
  HexRenderSession({
    Future<List<HexCoverageCluster>> Function(
      List<CoverageZone> zones,
      int scale,
    )?
    aggregate,
  }) : _aggregate = aggregate ?? _aggregateCoverageOffUi;

  final Future<List<HexCoverageCluster>> Function(
    List<CoverageZone> zones,
    int scale,
  )
  _aggregate;

  int _generation = 0;
  int? _identity;
  final Map<int, List<HexCoverageCluster>> _cache =
      <int, List<HexCoverageCluster>>{};
  final Map<int, Future<List<HexCoverageCluster>>> _inflight =
      <int, Future<List<HexCoverageCluster>>>{};

  int? get identity => _identity;

  void reset(int identity) {
    if (_identity == identity) return;
    _identity = identity;
    _generation++;
    _cache.clear();
    _inflight.clear();
  }

  /// Draws [zones] for [viewport] at true size. Returns null when [identity]
  /// changed before the aggregate finished.
  ///
  /// Pan and zoom reuse the scale-1 cache. A new filter identity drops it.
  Future<MapRenderPlan?> render({
    required int identity,
    required List<CoverageZone> zones,
    required MapRenderViewport viewport,
  }) async {
    if (_identity != identity) reset(identity);
    final generation = _generation;
    final loaded = await _load(generation, identity, zones, mapTrueSizeScale);
    if (loaded == null || _generation != generation || _identity != identity) {
      return null;
    }
    final attempt = resolveMapRender(
      zones: zones,
      viewport: viewport,
      lookup: (scale) => _cache[scale],
    );
    if (attempt is MapRenderReady) return attempt.plan;
    return null;
  }

  Future<List<HexCoverageCluster>?> _load(
    int generation,
    int identity,
    List<CoverageZone> zones,
    int scale,
  ) async {
    if (_generation != generation || _identity != identity) return null;
    final cached = _cache[scale];
    if (cached != null) return cached;
    final existing = _inflight[scale];
    final Future<List<HexCoverageCluster>> future;
    if (existing != null) {
      future = existing;
    } else {
      future = _aggregate(zones, scale);
      _inflight[scale] = future;
    }
    List<HexCoverageCluster> built;
    try {
      built = await future;
    } finally {
      if (identical(_inflight[scale], future)) _inflight.remove(scale);
    }
    if (_generation != generation || _identity != identity) return null;
    _cache[scale] = built;
    return built;
  }
}

Future<List<HexCoverageCluster>> _aggregateCoverageOffUi(
  List<CoverageZone> zones,
  int scale,
) {
  return aggregateCoverageHexesOffUi(zones, scale: scale);
}

int mapDrawSignature(List<MapDrawPolygon> drawn) {
  var hash = drawn.length.hashCode;
  for (final polygon in drawn) {
    hash = Object.hash(
      hash,
      polygon.hitZoneId,
      polygon.isDeadZone,
      polygon.avgRssi,
      polygon.avgSnr,
      polygon.childCount,
      polygon.coveredCount,
      polygon.scale,
      polygon.points.length,
    );
    for (final point in polygon.points) {
      hash = Object.hash(hash, point.latitude, point.longitude);
    }
  }
  return hash;
}

MapDrawPolygon _polygonForCluster(HexCoverageCluster cluster) {
  return MapDrawPolygon(
    hitZoneId: cluster.hitZoneId,
    points: cluster.points,
    isDeadZone: cluster.isDeadZone,
    avgRssi: cluster.avgRssi,
    avgSnr: cluster.avgSnr,
    childCount: cluster.childCount,
    coveredCount: cluster.coveredCount,
    scale: cluster.scale,
    memberZoneIds: cluster.memberZoneIds,
  );
}

double _wrapLongitude(double longitude) {
  if (!longitude.isFinite) return 0;
  var wrapped = longitude % 360;
  if (wrapped > 180) wrapped -= 360;
  if (wrapped < -180) wrapped += 360;
  return wrapped;
}

bool _longitudeInRange(
  double longitude, {
  required double west,
  required double east,
  required bool crossesAntimeridian,
}) {
  final wrapped = _wrapLongitude(longitude);
  if (crossesAntimeridian) {
    return wrapped >= west || wrapped <= east;
  }
  return wrapped >= west && wrapped <= east;
}

bool _clusterIntersectsViewport(
  HexCoverageCluster cluster,
  MapRenderViewport viewport,
) {
  return _geometryIntersectsViewport(
    centerLat: cluster.centerLat,
    centerLng: cluster.centerLng,
    points: cluster.points,
    viewport: viewport,
  );
}

bool _geometryIntersectsViewport({
  required double centerLat,
  required double centerLng,
  required List<LatLng> points,
  required MapRenderViewport viewport,
}) {
  if (!centerLat.isFinite || !centerLng.isFinite) return false;
  final latitudes = _latitudeSpan(centerLat, points);
  if (latitudes.$1 > viewport.north || latitudes.$2 < viewport.south) {
    return false;
  }
  if (viewport.spansAllLongitudes) return true;
  final longitudes = _longitudeSpan(centerLng, points);
  return _longitudeRangesOverlap(
    aWest: viewport.west,
    aEast: viewport.east,
    aCrosses: viewport.crossesAntimeridian,
    bWest: longitudes.$1,
    bEast: longitudes.$2,
    bCrosses: longitudes.$3,
  );
}

(double, double) _latitudeSpan(double centerLat, List<LatLng> points) {
  var south = centerLat;
  var north = centerLat;
  for (final point in points) {
    if (!point.latitude.isFinite) continue;
    if (point.latitude < south) south = point.latitude;
    if (point.latitude > north) north = point.latitude;
  }
  return (south, north);
}

/// West, east, and whether the ring crosses the antimeridian.
(double, double, bool) _longitudeSpan(double centerLng, List<LatLng> points) {
  final raw = <double>[centerLng];
  for (final point in points) {
    if (!point.longitude.isFinite) continue;
    raw.add(point.longitude);
  }
  var minL = raw.first;
  var maxL = raw.first;
  for (final value in raw) {
    if (value < minL) minL = value;
    if (value > maxL) maxL = value;
  }
  // A parent hex near ±180 is stored unwrapped so its edges stay short.
  if (maxL - minL <= 180) {
    final crosses = minL < -180 || maxL > 180;
    if (!crosses) return (minL, maxL, false);
    return (_wrapLongitude(minL), _wrapLongitude(maxL), true);
  }

  final longitudes = <double>[for (final value in raw) _wrapLongitude(value)];
  longitudes.sort();
  var largestGap = -1.0;
  var gapAfter = 0;
  for (var i = 0; i < longitudes.length - 1; i++) {
    final gap = longitudes[i + 1] - longitudes[i];
    if (gap > largestGap) {
      largestGap = gap;
      gapAfter = i;
    }
  }
  final wrapGap = (longitudes.first + 360) - longitudes.last;
  if (wrapGap >= largestGap) {
    return (longitudes.first, longitudes.last, false);
  }
  return (longitudes[gapAfter + 1], longitudes[gapAfter], true);
}

bool _longitudeRangesOverlap({
  required double aWest,
  required double aEast,
  required bool aCrosses,
  required double bWest,
  required double bEast,
  required bool bCrosses,
}) {
  if (_longitudeInRange(
    bWest,
    west: aWest,
    east: aEast,
    crossesAntimeridian: aCrosses,
  )) {
    return true;
  }
  if (_longitudeInRange(
    bEast,
    west: aWest,
    east: aEast,
    crossesAntimeridian: aCrosses,
  )) {
    return true;
  }
  if (_longitudeInRange(
    aWest,
    west: bWest,
    east: bEast,
    crossesAntimeridian: bCrosses,
  )) {
    return true;
  }
  return _longitudeInRange(
    aEast,
    west: bWest,
    east: bEast,
    crossesAntimeridian: bCrosses,
  );
}
