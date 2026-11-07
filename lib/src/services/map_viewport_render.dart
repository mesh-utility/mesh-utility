import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/grid.dart';

/// Extra fraction of the camera kept on each edge so hexes do not pop
/// while the view is still moving.
const double mapViewportMarginFraction = 0.15;

/// Polygons passed to the map layer. All-time history is about 9k zones;
/// drawing that set on every frame stalls input.
const int mapMaxDrawnPolygons = 700;

/// At or above this zoom, draw the real hex. Below it, bin into cells so
/// coverage stays visible when a hex is smaller than a pixel.
const double mapDetailZoom = 12.5;

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
  });

  final String hitZoneId;
  final List<LatLng> points;
  final bool isDeadZone;
  final double? avgRssi;
  final double? avgSnr;
}

/// Zones to paint for [viewport].
///
/// The input list is not modified. Stats and filters stay on that full
/// selection; this only chooses what the layer draws.
///
/// At or above [detailZoom], result polygons are the zone hexes (spatially
/// thinned if there are more than [maxDrawn] in view). Below [detailZoom],
/// zones are binned into at most [maxDrawn] world-aligned cells.
List<MapDrawPolygon> selectZonesForMapRender({
  required List<CoverageZone> zones,
  required MapRenderViewport viewport,
  int maxDrawn = mapMaxDrawnPolygons,
  double detailZoom = mapDetailZoom,
  String? pinZoneId,
}) {
  final cap = maxDrawn < 1 ? 1 : maxDrawn;
  final visible = <CoverageZone>[];
  for (final zone in zones) {
    if (_zoneIntersectsViewport(zone, viewport)) visible.add(zone);
  }
  if (visible.isEmpty) return const <MapDrawPolygon>[];

  final zoom = viewport.zoom.isFinite ? viewport.zoom : 0.0;
  final List<MapDrawPolygon> drawn;
  if (zoom >= detailZoom && visible.length <= cap) {
    drawn = _individualPolygons(visible);
  } else if (zoom >= detailZoom) {
    drawn = _binnedPolygons(visible, zoom: zoom, cap: cap, asCells: false);
  } else {
    drawn = _binnedPolygons(visible, zoom: zoom, cap: cap, asCells: true);
  }
  return _pinZone(
    drawn: drawn,
    visible: visible,
    pinZoneId: pinZoneId,
    cap: cap,
  );
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
      polygon.points.length,
    );
    for (final point in polygon.points) {
      hash = Object.hash(hash, point.latitude, point.longitude);
    }
  }
  return hash;
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

bool _zoneIntersectsViewport(CoverageZone zone, MapRenderViewport viewport) {
  if (!zone.centerLat.isFinite || !zone.centerLng.isFinite) return false;
  final latitudes = _latitudeSpan(zone);
  if (latitudes.$1 > viewport.north || latitudes.$2 < viewport.south) {
    return false;
  }
  if (viewport.spansAllLongitudes) return true;
  final longitudes = _longitudeSpan(zone);
  return _longitudeRangesOverlap(
    aWest: viewport.west,
    aEast: viewport.east,
    aCrosses: viewport.crossesAntimeridian,
    bWest: longitudes.$1,
    bEast: longitudes.$2,
    bCrosses: longitudes.$3,
  );
}

(double, double) _latitudeSpan(CoverageZone zone) {
  var south = zone.centerLat;
  var north = zone.centerLat;
  for (final point in zone.polygon) {
    if (!point.latitude.isFinite) continue;
    if (point.latitude < south) south = point.latitude;
    if (point.latitude > north) north = point.latitude;
  }
  return (south, north);
}

/// West, east, and whether the ring crosses the antimeridian.
(double, double, bool) _longitudeSpan(CoverageZone zone) {
  final longitudes = <double>[_wrapLongitude(zone.centerLng)];
  for (final point in zone.polygon) {
    if (!point.longitude.isFinite) continue;
    longitudes.add(_wrapLongitude(point.longitude));
  }
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
  // The empty arc is interior, so the ring crosses ±180.
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

List<MapDrawPolygon> _individualPolygons(List<CoverageZone> zones) {
  final drawn = <MapDrawPolygon>[];
  for (final zone in zones) {
    if (zone.polygon.length < 3) continue;
    drawn.add(_polygonForZone(zone));
  }
  return drawn;
}

MapDrawPolygon _polygonForZone(CoverageZone zone) {
  return MapDrawPolygon(
    hitZoneId: zone.id,
    points: zone.polygon,
    isDeadZone: zone.isDeadZone,
    avgRssi: zone.avgRssi,
    avgSnr: zone.avgSnr,
  );
}

double _startCellDegrees(double zoom) {
  final clamped = zoom < 0 ? 0.0 : (zoom > 22 ? 22.0 : zoom);
  final worldPixels = 256.0 * math.pow(2.0, clamped).toDouble();
  final degreesPerPixel = 360.0 / worldPixels;
  final visibleCell = degreesPerPixel * 10;
  final hexCell = hexSize * 2;
  return visibleCell > hexCell ? visibleCell : hexCell;
}

({int rowCount, int colCount, double cellLat, double cellLng}) _worldGrid(
  double cellDegrees,
) {
  final safe = cellDegrees < 1e-4 ? 1e-4 : cellDegrees;
  final colCount = math.max(1, (360 / safe).ceil());
  final rowCount = math.max(1, (180 / safe).ceil());
  return (
    rowCount: rowCount,
    colCount: colCount,
    cellLat: 180 / rowCount,
    cellLng: 360 / colCount,
  );
}

List<MapDrawPolygon> _binnedPolygons(
  List<CoverageZone> zones, {
  required double zoom,
  required int cap,
  required bool asCells,
}) {
  var cell = _startCellDegrees(zoom);
  var grid = _worldGrid(cell);
  var groups = <int, List<CoverageZone>>{};
  for (var attempt = 0; attempt < 30; attempt++) {
    grid = _worldGrid(cell);
    groups = _groupZones(zones, grid);
    if (groups.length <= cap) break;
    cell *= 1.7;
  }

  final keys = groups.keys.toList()..sort();
  if (keys.length > cap) {
    final step = keys.length / cap;
    final sampled = <int>[];
    for (var i = 0; i < cap; i++) {
      sampled.add(keys[(i * step).floor()]);
    }
    keys
      ..clear()
      ..addAll(sampled);
  }

  final drawn = <MapDrawPolygon>[];
  for (final key in keys) {
    if (drawn.length >= cap) break;
    final group = groups[key];
    if (group == null || group.isEmpty) continue;
    if (asCells) {
      final cellPolygon = _cellPolygon(key, grid, group);
      if (cellPolygon != null) drawn.add(cellPolygon);
      continue;
    }
    final representative = _representative(group);
    if (representative.polygon.length < 3) continue;
    drawn.add(_polygonForZone(representative));
  }
  return drawn;
}

Map<int, List<CoverageZone>> _groupZones(
  List<CoverageZone> zones,
  ({int rowCount, int colCount, double cellLat, double cellLng}) grid,
) {
  final groups = <int, List<CoverageZone>>{};
  for (final zone in zones) {
    var row = ((zone.centerLat + 90) / grid.cellLat).floor();
    if (row < 0) row = 0;
    if (row >= grid.rowCount) row = grid.rowCount - 1;
    var col = ((_wrapLongitude(zone.centerLng) + 180) / grid.cellLng).floor();
    if (col < 0) col = 0;
    if (col >= grid.colCount) col = grid.colCount - 1;
    final key = row * grid.colCount + col;
    groups.putIfAbsent(key, () => <CoverageZone>[]).add(zone);
  }
  return groups;
}

MapDrawPolygon? _cellPolygon(
  int key,
  ({int rowCount, int colCount, double cellLat, double cellLng}) grid,
  List<CoverageZone> group,
) {
  final row = key ~/ grid.colCount;
  final col = key % grid.colCount;
  final south = -90 + row * grid.cellLat;
  final north = math.min(90.0, south + grid.cellLat);
  final west = -180 + col * grid.cellLng;
  final east = math.min(180.0, west + grid.cellLng);
  if (north - south < 1e-9 || east - west < 1e-9) return null;
  final representative = _representative(group);
  var heard = 0;
  var rssiSum = 0.0;
  var rssiCount = 0;
  var snrSum = 0.0;
  var snrCount = 0;
  for (final zone in group) {
    if (zone.isDeadZone) continue;
    heard++;
    final rssi = zone.avgRssi;
    if (rssi != null && rssi.isFinite) {
      rssiSum += rssi;
      rssiCount++;
    }
    final snr = zone.avgSnr;
    if (snr != null && snr.isFinite) {
      snrSum += snr;
      snrCount++;
    }
  }
  final isDeadZone = heard == 0;
  return MapDrawPolygon(
    hitZoneId: representative.id,
    points: <LatLng>[
      LatLng(south, west),
      LatLng(south, east),
      LatLng(north, east),
      LatLng(north, west),
    ],
    isDeadZone: isDeadZone,
    avgRssi: isDeadZone || rssiCount == 0 ? null : rssiSum / rssiCount,
    avgSnr: isDeadZone || snrCount == 0 ? null : snrSum / snrCount,
  );
}

CoverageZone _representative(List<CoverageZone> group) {
  var poolIsHeard = false;
  for (final zone in group) {
    if (!zone.isDeadZone) {
      poolIsHeard = true;
      break;
    }
  }
  CoverageZone? best;
  for (final zone in group) {
    if (poolIsHeard && zone.isDeadZone) continue;
    if (best == null || _outranks(zone, best)) best = zone;
  }
  return best ?? group.first;
}

bool _outranks(CoverageZone candidate, CoverageZone current) {
  if (candidate.scanCount != current.scanCount) {
    return candidate.scanCount > current.scanCount;
  }
  if (candidate.lastScanned != current.lastScanned) {
    return candidate.lastScanned.isAfter(current.lastScanned);
  }
  return candidate.id.compareTo(current.id) < 0;
}

List<MapDrawPolygon> _pinZone({
  required List<MapDrawPolygon> drawn,
  required List<CoverageZone> visible,
  required String? pinZoneId,
  required int cap,
}) {
  if (pinZoneId == null || pinZoneId.isEmpty) return drawn;
  for (final polygon in drawn) {
    if (polygon.hitZoneId == pinZoneId) return drawn;
  }
  CoverageZone? pinned;
  for (final zone in visible) {
    if (zone.id == pinZoneId) {
      pinned = zone;
      break;
    }
  }
  if (pinned == null || pinned.polygon.length < 3) return drawn;
  final polygon = _polygonForZone(pinned);
  if (drawn.length < cap) {
    return <MapDrawPolygon>[...drawn, polygon];
  }
  if (drawn.isEmpty) return <MapDrawPolygon>[polygon];
  final copy = List<MapDrawPolygon>.of(drawn);
  copy[copy.length - 1] = polygon;
  return copy;
}
