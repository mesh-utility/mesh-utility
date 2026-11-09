import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/map_camera.dart';
import 'package:mesh_utility/src/services/map_viewport_render.dart';
import 'package:mesh_utility/src/services/reax_database.dart';

/// Hit values for overview hexes. Detailed zone ids never use this prefix.
const String overviewHitPrefix = 'ov:';

/// Local copy is reused for this long, then fetched again.
const Duration overviewCacheTtl = Duration(hours: 1);

const String overviewCacheStorageKey = 'coverage:overview';

/// One coarse cell from GET /coverage/overview.
///
/// [id] is `row:col` on the scale-256 grid. The center is that cell's snapped
/// center, not a scan coordinate.
class CoverageOverviewCell {
  const CoverageOverviewCell({
    required this.row,
    required this.col,
    required this.strength,
    required this.recency,
    this.countBucket,
  });

  final int row;
  final int col;

  /// 0 little or none, 1 weak, 2 marginal, 3 fair, 4 strong.
  final int strength;

  /// 0 past week, 1 past month, 2 older.
  final int recency;

  /// Optional coarse count. Null when the server omitted it.
  final int? countBucket;

  String get id => '$row:$col';

  ({double lat, double lng}) get center =>
      hexCellCenter(row, col, scale: mapHexMaxScale);

  Map<String, Object?> toJson() => {
    'id': id,
    's': strength,
    'r': recency,
    if (countBucket != null) 'n': countBucket,
  };
}

class CoverageOverview {
  const CoverageOverview({
    required this.cells,
    required this.fetchedAt,
    this.generatedDay,
    this.scale = mapHexMaxScale,
  });

  final List<CoverageOverviewCell> cells;
  final DateTime fetchedAt;
  final String? generatedDay;
  final int scale;

  Map<String, Object?> toJson() => {
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    if (generatedDay != null) 'generatedDay': generatedDay,
    'scale': scale,
    'cells': cells.map((cell) => cell.toJson()).toList(growable: false),
  };
}

final RegExp _overviewDay = RegExp(r'^\d{4}-\d{2}-\d{2}$');

int? _bucket(Object? raw, int max) {
  if (raw is! num) return null;
  final value = raw.toInt();
  if (value < 0 || value > max) return null;
  return value;
}

CoverageOverviewCell? _parseCell(Map<dynamic, dynamic> raw) {
  int? row;
  int? col;
  final id = raw['id']?.toString();
  if (id != null) {
    final parts = id.split(':');
    if (parts.length == 2) {
      row = int.tryParse(parts[0]);
      col = int.tryParse(parts[1]);
    }
  }
  if (row == null && raw['row'] is num) row = (raw['row'] as num).toInt();
  if (col == null && raw['col'] is num) col = (raw['col'] as num).toInt();
  if (row == null || col == null) return null;
  final strength = _bucket(raw['s'] ?? raw['strength'], 4);
  final recency = _bucket(raw['r'] ?? raw['recency'], 2);
  if (strength == null || recency == null) return null;
  return CoverageOverviewCell(
    row: row,
    col: col,
    strength: strength,
    recency: recency,
    countBucket: _bucket(raw['n'] ?? raw['countBucket'], 4),
  );
}

/// Parses a worker body or a stored envelope. Extra fields are ignored.
///
/// Returns null when the scale is not [mapHexMaxScale] or the body is not
/// an object. A 404 is handled by the caller, not here.
CoverageOverview? parseCoverageOverview(Object? raw, {DateTime? fetchedAt}) {
  if (raw is! Map) return null;
  final scaleRaw = raw['scale'];
  final scale = scaleRaw == null
      ? mapHexMaxScale
      : (scaleRaw is num ? scaleRaw.toInt() : null);
  if (scale == null || scale != mapHexMaxScale) return null;
  final cellsRaw = raw['cells'];
  if (cellsRaw is! List) return null;
  final cells = <CoverageOverviewCell>[];
  for (final entry in cellsRaw) {
    if (entry is! Map) continue;
    final cell = _parseCell(entry);
    if (cell != null) cells.add(cell);
  }
  final day = raw['generatedDay']?.toString();
  final generatedDay = day != null && _overviewDay.hasMatch(day) ? day : null;
  final storedAt = DateTime.tryParse(
    raw['fetchedAt']?.toString() ?? '',
  )?.toUtc();
  return CoverageOverview(
    cells: cells,
    fetchedAt: (fetchedAt ?? storedAt ?? DateTime.now()).toUtc(),
    generatedDay: generatedDay,
    scale: scale,
  );
}

class StoredCoverageOverview {
  const StoredCoverageOverview({required this.overview, required this.fresh});

  final CoverageOverview overview;
  final bool fresh;
}

class CoverageOverviewCache {
  CoverageOverviewCache({
    Future<Object?> Function()? read,
    Future<void> Function(Object? value)? write,
    DateTime Function()? now,
  }) : _read = read,
       _write = write,
       _now = now ?? (() => DateTime.now().toUtc());

  final Future<Object?> Function()? _read;
  final Future<void> Function(Object? value)? _write;
  final DateTime Function() _now;

  Future<Object?> _readValue() async {
    if (_read != null) return _read();
    final db = await ReaxDatabase.instance();
    return db.get(overviewCacheStorageKey);
  }

  Future<void> _writeValue(Object? value) async {
    if (_write != null) {
      await _write(value);
      return;
    }
    final db = await ReaxDatabase.instance();
    await db.put(overviewCacheStorageKey, value);
  }

  bool isFresh(DateTime fetchedAt, [DateTime? now]) {
    final clock = (now ?? _now()).toUtc();
    return clock.difference(fetchedAt.toUtc()) < overviewCacheTtl;
  }

  Future<StoredCoverageOverview?> load() async {
    final decoded = _decodeStored(await _readValue());
    if (decoded is! Map || decoded['fetchedAt'] == null) return null;
    final overview = parseCoverageOverview(decoded);
    if (overview == null) return null;
    return StoredCoverageOverview(
      overview: overview,
      fresh: isFresh(overview.fetchedAt),
    );
  }

  Future<void> save(CoverageOverview overview) {
    return _writeValue(overview.toJson());
  }
}

Object? _decodeStored(Object? raw) {
  if (raw == null) return null;
  if (raw is Map) return raw;
  if (raw is String && raw.isNotEmpty) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// Opening camera. [overviewCells] are paint only and are not a location.
MapCameraStart mapCameraOnOpen({
  required double? ownLatitude,
  required double? ownLongitude,
  List<CoverageOverviewCell> overviewCells = const [],
}) {
  assert(overviewCells.every((cell) => cell.strength >= 0));
  return initialMapCamera(
    ownLatitude: ownLatitude,
    ownLongitude: ownLongitude,
  );
}

String overviewStrengthLabel(int strength) {
  switch (strength) {
    case 4:
      return 'Strong';
    case 3:
      return 'Fair';
    case 2:
      return 'Marginal';
    case 1:
      return 'Weak';
    default:
      return 'Little or none';
  }
}

String overviewRecencyLabel(int recency) {
  switch (recency) {
    case 0:
      return 'Past week';
    case 1:
      return 'Past month';
    default:
      return 'Older';
  }
}

/// Tooltip copy. Strength and recency buckets only.
String overviewTooltipText({required int strength, required int recency}) {
  return 'General coverage (approx.) — Sync or zoom in for details\n'
      '${overviewStrengthLabel(strength)} · ${overviewRecencyLabel(recency)}';
}

Color overviewStrengthColor(int strength) {
  switch (strength) {
    case 4:
      return const Color(0xFF22C55E);
    case 3:
      return const Color(0xFFFACC15);
    case 2:
      return const Color(0xFFF97316);
    case 1:
      return const Color(0xFFEF4444);
    default:
      return const Color(0xFF991B1B);
  }
}

Color overviewFillColor(int strength, int recency) {
  final alpha = switch (recency) {
    0 => 0.22,
    1 => 0.14,
    _ => 0.08,
  };
  return overviewStrengthColor(strength).withValues(alpha: alpha);
}

Color overviewBorderColor(int strength, int recency) {
  final alpha = switch (recency) {
    0 => 0.55,
    1 => 0.35,
    _ => 0.22,
  };
  return overviewStrengthColor(strength).withValues(alpha: alpha);
}

bool overviewPointInView({
  required double lat,
  required double lng,
  required double south,
  required double north,
  required double west,
  required double east,
  required bool crossesAntimeridian,
  required bool spansAllLongitudes,
}) {
  if (!lat.isFinite || !lng.isFinite) return false;
  if (lat < south || lat > north) return false;
  if (spansAllLongitudes) return true;
  if (!crossesAntimeridian) return lng >= west && lng <= east;
  return lng >= west || lng <= east;
}

/// True when zoomed in far enough that detailed hexes replace the overview
/// and at least one detailed center is inside the view.
bool overviewLayerShown({
  required double zoom,
  required bool detailedDataInView,
}) {
  final z = zoom.isFinite ? zoom : 0;
  if (detailedDataInView && z >= mapHexMaxScaleZoom) return false;
  return true;
}

class OverviewHexDraw {
  const OverviewHexDraw({
    required this.hitId,
    required this.points,
    required this.fill,
    required this.border,
    required this.cell,
  });

  final String hitId;
  final List<LatLng> points;
  final Color fill;
  final Color border;
  final CoverageOverviewCell cell;
}

class OverviewLayerPlan {
  const OverviewLayerPlan({required this.showLayer, required this.draws});

  final bool showLayer;
  final List<OverviewHexDraw> draws;
}

/// Faint base hexes for the current view.
///
/// Cells that share a scale-256 parent with detailed coverage are omitted.
/// Above [mapHexMaxScaleZoom], the whole layer hides when detailed coverage
/// is in the view. The plan has no camera target.
OverviewLayerPlan planOverviewLayer({
  required List<CoverageOverviewCell> cells,
  required double zoom,
  required Iterable<({double lat, double lng})> detailedCenters,
  required double south,
  required double north,
  required double west,
  required double east,
  required bool crossesAntimeridian,
  required bool spansAllLongitudes,
  required double centerLat,
  required double centerLng,
  int cap = mapMaxDrawnPolygons,
}) {
  var detailedInView = false;
  final detailedParents = <String>{};
  for (final point in detailedCenters) {
    final parent = hexCellAt(point.lat, point.lng, scale: mapHexMaxScale);
    detailedParents.add('${parent.row}:${parent.col}');
    if (overviewPointInView(
      lat: point.lat,
      lng: point.lng,
      south: south,
      north: north,
      west: west,
      east: east,
      crossesAntimeridian: crossesAntimeridian,
      spansAllLongitudes: spansAllLongitudes,
    )) {
      detailedInView = true;
    }
  }
  final showLayer = overviewLayerShown(
    zoom: zoom,
    detailedDataInView: detailedInView,
  );
  if (!showLayer || cells.isEmpty) {
    return OverviewLayerPlan(showLayer: showLayer, draws: const []);
  }

  final visible = <CoverageOverviewCell>[];
  for (final cell in cells) {
    if (detailedParents.contains(cell.id)) continue;
    final at = cell.center;
    if (!overviewPointInView(
      lat: at.lat,
      lng: at.lng,
      south: south,
      north: north,
      west: west,
      east: east,
      crossesAntimeridian: crossesAntimeridian,
      spansAllLongitudes: spansAllLongitudes,
    )) {
      continue;
    }
    visible.add(cell);
  }
  if (visible.length > cap) {
    visible.sort((a, b) {
      final aCenter = a.center;
      final bCenter = b.center;
      final delta = distanceMiles(
        centerLat,
        centerLng,
        aCenter.lat,
        aCenter.lng,
      ).compareTo(distanceMiles(centerLat, centerLng, bCenter.lat, bCenter.lng));
      if (delta != 0) return delta;
      return a.id.compareTo(b.id);
    });
    visible.removeRange(cap, visible.length);
  }

  final draws = <OverviewHexDraw>[
    for (final cell in visible)
      OverviewHexDraw(
        hitId: '$overviewHitPrefix${cell.id}',
        points: hexVertices(
          cell.center.lat,
          cell.center.lng,
          scale: mapHexMaxScale,
        ),
        fill: overviewFillColor(cell.strength, cell.recency),
        border: overviewBorderColor(cell.strength, cell.recency),
        cell: cell,
      ),
  ];
  return OverviewLayerPlan(showLayer: true, draws: draws);
}
