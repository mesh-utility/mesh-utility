import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

/// One true-size hex to paint in a single batched layer.
///
/// Hexes are never merged, dropped, resized, or moved — each keeps its
/// own ring on the fixed grid.
class CoverageBatchHex {
  const CoverageBatchHex({
    required this.points,
    required this.hitId,
    required this.fill,
    required this.border,
  });

  final List<LatLng> points;
  final String hitId;
  final Color fill;
  final Color border;
}

/// Batched coverage paint for flutter_map. One [CustomPainter] draws every
/// hex fill/border; hit-testing is done by the map page via
/// [hitTestCoverageBatchHexes] so pan/zoom stay with FlutterMap.
///
/// Hex rings are projected once into a [CoverageHexGeometry] and reused on
/// every camera frame. A pan or pinch only changes the canvas transform, so
/// the per-frame cost no longer grows with the number of hex vertices.
class CoverageHexBatchLayer extends StatefulWidget {
  const CoverageHexBatchLayer({super.key, required this.hexes});

  final List<CoverageBatchHex> hexes;

  @override
  State<CoverageHexBatchLayer> createState() => _CoverageHexBatchLayerState();
}

class _CoverageHexBatchLayerState extends State<CoverageHexBatchLayer> {
  /// Quiet time after the last camera frame before a zoom-drifted geometry
  /// is rebuilt at the settled zoom.
  static const Duration _settleDelay = Duration(milliseconds: 250);

  CoverageHexGeometry? _geometry;
  Timer? _settleTimer;
  bool _rebuildOnSettle = false;

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  void _scheduleSettleRebuild() {
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDelay, () {
      _settleTimer = null;
      if (!mounted) return;
      setState(() => _rebuildOnSettle = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    var geometry = _geometry;
    if (geometry == null) {
      geometry = CoverageHexGeometry.build(widget.hexes, camera);
    } else if (_rebuildOnSettle && !geometry.settledFor(camera)) {
      geometry = CoverageHexGeometry.build(widget.hexes, camera);
    } else if (!identical(geometry.hexes, widget.hexes)) {
      // In-view list refresh: keep the reference frame, reuse projected
      // rings and unchanged buckets.
      geometry = CoverageHexGeometry.update(geometry, widget.hexes, camera);
    } else if (!geometry.usableFor(camera)) {
      geometry = CoverageHexGeometry.build(widget.hexes, camera);
    }
    _rebuildOnSettle = false;
    _geometry = geometry;
    if (geometry.settledFor(camera)) {
      _settleTimer?.cancel();
      _settleTimer = null;
    } else {
      // Mid-gesture zoom drift: keep painting the cached geometry (still
      // exact) and re-project once the camera stops moving.
      _scheduleSettleRebuild();
    }
    return MobileLayerTransformer(
      child: CustomPaint(
        size: camera.size,
        painter: _CoverageHexBatchPainter(camera: camera, geometry: geometry),
      ),
    );
  }
}

/// Unrotated layer-space offset of [point], matching flutter_map's
/// [PolygonLayer] and tiles: `projectAtZoom(point) - pixelOrigin`
/// (same as [MapCamera.getOffsetFromOrigin]).
///
/// [MapCamera.latLngToScreenOffset] already applies rotation and uses
/// [MapCamera.nonRotatedSize] for its origin. Painting that result inside
/// [MobileLayerTransformer] (which rotates again) makes hexes drift off the
/// basemap during pinch-zoom/rotate. This helper stays in layer space so the
/// transformer applies rotation once. Tiles use the unrounded
/// [MapCamera.pixelOrigin] getter, not the rounded [MapCamera.getNewPixelOrigin].
Offset coverageHexLayerOffset(MapCamera camera, LatLng point) {
  return camera.getOffsetFromOrigin(point);
}

/// Maps a screen-space offset such as [TapPosition.relative] into the same
/// unrotated layer space [coverageHexLayerOffset] uses, by inverting
/// [MobileLayerTransformer]'s rotation about [MapCamera.size]'s center.
Offset coverageHexScreenToLayer(MapCamera camera, Offset screen) {
  if (camera.rotation == 0.0) return screen;
  return camera.rotatePoint(
    camera.size.center(Offset.zero),
    screen,
    counterRotation: true,
  );
}

/// Reverse-order point-in-polygon so the last-drawn (top) hex wins.
///
/// A miss is always null. Callers must not treat a miss as the previously
/// selected hex — an empty tap dismisses, and a rebuild must not re-select.
String? hitTestCoverageBatchHexes(LatLng point, List<CoverageBatchHex> hexes) {
  if (!point.latitude.isFinite || !point.longitude.isFinite) return null;
  for (var i = hexes.length - 1; i >= 0; i--) {
    final hex = hexes[i];
    if (hex.points.length < 3) continue;
    if (!pointInLatLngRing(point, hex.points)) continue;
    return hex.hitId;
  }
  return null;
}

/// Hit-test in the same pixel space [CoverageHexBatchLayer] paints.
///
/// [project] must be the same layer-space projection used to draw the rings
/// ([coverageHexLayerOffset]). Convert screen taps with
/// [coverageHexScreenToLayer] first. Map taps are reported in screen space,
/// and an overlay rebuild can move the camera before a delayed tap is
/// delivered. A finger on empty pixels misses even if that converted lat/lng
/// falls inside a ring.
String? hitTestCoverageBatchHexesOnScreen(
  Offset screenPoint,
  List<CoverageBatchHex> hexes,
  Offset Function(LatLng point) project,
) {
  if (!screenPoint.dx.isFinite || !screenPoint.dy.isFinite) return null;
  for (var i = hexes.length - 1; i >= 0; i--) {
    final hex = hexes[i];
    if (hex.points.length < 3) continue;
    final ring = <Offset>[];
    var finite = true;
    for (final point in hex.points) {
      if (!point.latitude.isFinite || !point.longitude.isFinite) {
        finite = false;
        break;
      }
      final projected = project(point);
      if (!projected.dx.isFinite || !projected.dy.isFinite) {
        finite = false;
        break;
      }
      ring.add(projected);
    }
    if (!finite || ring.length < 3) continue;
    if (pointInOffsetRing(screenPoint, ring)) return hex.hitId;
  }
  return null;
}

/// Ray-cast point-in-polygon for a simple ring (no holes).
bool pointInLatLngRing(LatLng point, List<LatLng> ring) {
  if (!point.latitude.isFinite || !point.longitude.isFinite) return false;
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final pi = ring[i];
    final pj = ring[j];
    if (!pi.latitude.isFinite ||
        !pi.longitude.isFinite ||
        !pj.latitude.isFinite ||
        !pj.longitude.isFinite) {
      continue;
    }
    final crosses =
        (pi.latitude > point.latitude) != (pj.latitude > point.latitude);
    if (!crosses) continue;
    final dLat = pj.latitude - pi.latitude;
    if (dLat == 0) continue;
    final lngAtPoint =
        (pj.longitude - pi.longitude) * (point.latitude - pi.latitude) / dLat +
        pi.longitude;
    if (point.longitude < lngAtPoint) inside = !inside;
  }
  return inside;
}

/// Ray-cast point-in-polygon for a screen-space ring. Same even-odd rule as
/// [pointInLatLngRing]. Y grows downward; winding does not matter.
bool pointInOffsetRing(Offset point, List<Offset> ring) {
  if (!point.dx.isFinite || !point.dy.isFinite) return false;
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final pi = ring[i];
    final pj = ring[j];
    if (!pi.dx.isFinite ||
        !pi.dy.isFinite ||
        !pj.dx.isFinite ||
        !pj.dy.isFinite) {
      continue;
    }
    final crosses = (pi.dy > point.dy) != (pj.dy > point.dy);
    if (!crosses) continue;
    final dy = pj.dy - pi.dy;
    if (dy == 0) continue;
    final xAtPoint = (pj.dx - pi.dx) * (point.dy - pi.dy) / dy + pi.dx;
    if (point.dx < xAtPoint) inside = !inside;
  }
  return inside;
}

/// Hex rings projected once at a reference camera, grouped into spatial
/// buckets of per-color fill and border paths.
///
/// Each vertex is stored as [coverageHexLayerOffset] at [refZoom], so for
/// any later camera the painted position is exactly
/// `local * scale + (refOrigin * scale - pixelOrigin)` with
/// `scale = 2^(zoom - refZoom)`: Web Mercator pixel coordinates are linear in
/// the zoom scale. The geometry (true-size rings on the fixed grid) is never
/// changed; only the canvas transform moves with the camera, and rotation is
/// still applied once by [MobileLayerTransformer].
class CoverageHexGeometry {
  CoverageHexGeometry._({
    required this.hexes,
    required this.refZoom,
    required this.refOrigin,
    required this.crs,
    required Map<int, _HexBucket> buckets,
    required Map<CoverageBatchHex, List<Offset>> rings,
    this.reusedBucketCount = 0,
  }) : _byKey = buckets,
       _buckets = buckets.values.toList(growable: false),
       _rings = rings;

  /// Side of a spatial bucket in reference-zoom pixels.
  static const double bucketSize = 512;

  /// Zoom-in past [refZoom] after which the geometry is re-projected once
  /// the camera settles (keeps culling buckets a useful size).
  static const double maxZoomInDelta = 1.5;

  /// Zoom-out below [refZoom] after which the geometry is re-projected once
  /// the camera settles.
  static const double maxZoomOutDelta = 3;

  /// Mid-gesture limit: past this the geometry is rebuilt immediately even
  /// while the camera is still moving. Float path coordinates stay well
  /// under a pixel of error inside this range.
  static const double maxGestureZoomDelta = 5;

  /// Farthest the camera may pan from [refOrigin] (reference pixels) before
  /// an in-view refresh starts a new reference frame.
  static const double maxFrameDrift = 20000;

  final List<CoverageBatchHex> hexes;
  final double refZoom;
  final Offset refOrigin;
  final Crs crs;
  final Map<int, _HexBucket> _byKey;
  final List<_HexBucket> _buckets;
  final Map<CoverageBatchHex, List<Offset>> _rings;

  /// Number of non-empty spatial buckets (for tests).
  int get bucketCount => _buckets.length;

  /// Buckets carried over unchanged from the previous geometry by [update].
  final int reusedBucketCount;

  factory CoverageHexGeometry.build(
    List<CoverageBatchHex> hexes,
    MapCamera camera,
  ) {
    return _assemble(
      hexes: hexes,
      refZoom: camera.zoom,
      refOrigin: camera.pixelOrigin,
      crs: camera.crs,
      project: (point) => coverageHexLayerOffset(camera, point),
    );
  }

  /// Geometry for a new in-view [hexes] list that keeps [previous]'s
  /// reference frame when it still fits [camera]. Rings of hexes that were
  /// already drawn are not projected again, and buckets whose hexes did not
  /// change keep their paths.
  factory CoverageHexGeometry.update(
    CoverageHexGeometry previous,
    List<CoverageBatchHex> hexes,
    MapCamera camera,
  ) {
    if (!previous._frameFits(camera)) {
      return CoverageHexGeometry.build(hexes, camera);
    }
    final origin = previous.refOrigin;
    return _assemble(
      hexes: hexes,
      refZoom: previous.refZoom,
      refOrigin: origin,
      crs: previous.crs,
      project: (point) =>
          previous.crs.latLngToOffset(point, previous.refZoom) - origin,
      previous: previous,
    );
  }

  static CoverageHexGeometry _assemble({
    required List<CoverageBatchHex> hexes,
    required double refZoom,
    required Offset refOrigin,
    required Crs crs,
    required Offset Function(LatLng point) project,
    CoverageHexGeometry? previous,
  }) {
    final rings = Map<CoverageBatchHex, List<Offset>>.identity();
    final members = <int, List<CoverageBatchHex>>{};
    for (final hex in hexes) {
      if (hex.points.length < 3) continue;
      var ring = previous?._rings[hex];
      if (ring == null) {
        ring = <Offset>[];
        var finite = true;
        for (final point in hex.points) {
          final o = project(point);
          if (!o.dx.isFinite || !o.dy.isFinite) {
            finite = false;
            break;
          }
          ring.add(o);
        }
        if (!finite) continue;
      }
      rings[hex] = ring;
      final first = ring.first;
      final bx = (first.dx / bucketSize).floor();
      final by = (first.dy / bucketSize).floor();
      final key = (bx & 0x1FFFFF) << 21 | (by & 0x1FFFFF);
      (members[key] ??= <CoverageBatchHex>[]).add(hex);
    }
    final buckets = <int, _HexBucket>{};
    var reused = 0;
    for (final entry in members.entries) {
      final old = previous?._byKey[entry.key];
      if (old != null && old.sameHexes(entry.value)) {
        buckets[entry.key] = old;
        reused++;
      } else {
        buckets[entry.key] = _HexBucket.build(entry.value, rings);
      }
    }
    return CoverageHexGeometry._(
      hexes: hexes,
      refZoom: refZoom,
      refOrigin: refOrigin,
      crs: crs,
      buckets: buckets,
      rings: rings,
      reusedBucketCount: reused,
    );
  }

  bool _sameCrs(MapCamera camera) =>
      identical(camera.crs, crs) || camera.crs == crs;

  bool _frameFits(MapCamera camera) {
    if (!_sameCrs(camera)) return false;
    final delta = camera.zoom - refZoom;
    if (delta > maxZoomInDelta || delta < -maxZoomOutDelta) return false;
    final drift = camera.pixelOrigin / scaleFor(camera) - refOrigin;
    return drift.distance <= maxFrameDrift;
  }

  /// True when [camera] is close enough in zoom that no re-projection is
  /// wanted, even after the camera stops.
  bool settledFor(MapCamera camera) {
    if (!_sameCrs(camera)) return false;
    final delta = camera.zoom - refZoom;
    return delta <= maxZoomInDelta && delta >= -maxZoomOutDelta;
  }

  /// True when this geometry may still be painted for [camera] (possibly
  /// mid-gesture, before a settle rebuild).
  bool usableFor(MapCamera camera) {
    if (!_sameCrs(camera)) return false;
    return (camera.zoom - refZoom).abs() <= maxGestureZoomDelta;
  }

  /// True when [hexes] is the same list this geometry was built from and
  /// [camera] is close enough in zoom to reuse it.
  bool reusableFor(List<CoverageBatchHex> hexes, MapCamera camera) =>
      identical(hexes, this.hexes) && settledFor(camera);

  /// Zoom scale from [refZoom] to [camera].
  double scaleFor(MapCamera camera) =>
      camera.crs.scale(camera.zoom) / crs.scale(refZoom);

  /// Layer-space translation for [camera], applied after [scaleFor].
  Offset translationFor(MapCamera camera) =>
      refOrigin * scaleFor(camera) - camera.pixelOrigin;

  /// Painted layer-space position of a reference-zoom [local] point.
  Offset toLayer(Offset local, MapCamera camera) =>
      local * scaleFor(camera) + translationFor(camera);

  void paint(Canvas canvas, Size size, MapCamera camera) {
    if (_buckets.isEmpty) return;
    final scale = scaleFor(camera);
    if (!scale.isFinite || scale <= 0) return;
    final shift = translationFor(camera);
    if (!shift.dx.isFinite || !shift.dy.isFinite) return;

    // Visible layer rect. Under rotation the transformer turns this layer,
    // so keep the circle around the viewport that any rotation can show.
    Rect view = Offset.zero & size;
    if (camera.rotation != 0.0) {
      view = Rect.fromCircle(
        center: view.center,
        radius: Offset(size.width, size.height).distance / 2,
      );
    }
    view = view.inflate(4);
    final local = Rect.fromLTRB(
      (view.left - shift.dx) / scale,
      (view.top - shift.dy) / scale,
      (view.right - shift.dx) / scale,
      (view.bottom - shift.dy) / scale,
    );

    final visible = <_HexBucket>[];
    for (final bucket in _buckets) {
      if (bucket.overlaps(local)) visible.add(bucket);
    }
    if (visible.isEmpty) return;

    canvas
      ..save()
      ..translate(shift.dx, shift.dy)
      ..scale(scale);

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final bucket in visible) {
      for (final entry in bucket.fills.entries) {
        fillPaint.color = entry.key;
        canvas.drawPath(entry.value, fillPaint);
      }
    }

    // Borders stay 1 screen pixel while the canvas is scaled.
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 / scale
      ..isAntiAlias = true;
    for (final bucket in visible) {
      for (final entry in bucket.borders.entries) {
        borderPaint.color = entry.key;
        canvas.drawPath(entry.value, borderPaint);
      }
    }
    canvas.restore();
  }
}

class _HexBucket {
  _HexBucket._(this.hexes);

  factory _HexBucket.build(
    List<CoverageBatchHex> hexes,
    Map<CoverageBatchHex, List<Offset>> rings,
  ) {
    final bucket = _HexBucket._(hexes);
    for (final hex in hexes) {
      final ring = rings[hex]!;
      final fill = bucket.fills.putIfAbsent(hex.fill, Path.new);
      final border = bucket.borders.putIfAbsent(hex.border, Path.new);
      final first = ring.first;
      fill.moveTo(first.dx, first.dy);
      border.moveTo(first.dx, first.dy);
      bucket._include(first);
      for (var i = 1; i < ring.length; i++) {
        final o = ring[i];
        fill.lineTo(o.dx, o.dy);
        border.lineTo(o.dx, o.dy);
        bucket._include(o);
      }
      fill.close();
      border.close();
    }
    return bucket;
  }

  final List<CoverageBatchHex> hexes;
  final Map<Color, Path> fills = <Color, Path>{};
  final Map<Color, Path> borders = <Color, Path>{};
  double _minX = double.infinity;
  double _minY = double.infinity;
  double _maxX = double.negativeInfinity;
  double _maxY = double.negativeInfinity;

  bool sameHexes(List<CoverageBatchHex> other) {
    if (other.length != hexes.length) return false;
    for (var i = 0; i < other.length; i++) {
      if (!identical(other[i], hexes[i])) return false;
    }
    return true;
  }

  void _include(Offset o) {
    if (o.dx < _minX) _minX = o.dx;
    if (o.dy < _minY) _minY = o.dy;
    if (o.dx > _maxX) _maxX = o.dx;
    if (o.dy > _maxY) _maxY = o.dy;
  }

  bool overlaps(Rect r) =>
      _minX <= r.right &&
      _maxX >= r.left &&
      _minY <= r.bottom &&
      _maxY >= r.top;
}

class _CoverageHexBatchPainter extends CustomPainter {
  _CoverageHexBatchPainter({required this.camera, required this.geometry});

  final MapCamera camera;
  final CoverageHexGeometry geometry;

  @override
  void paint(Canvas canvas, Size size) => geometry.paint(canvas, size, camera);

  @override
  bool shouldRepaint(covariant _CoverageHexBatchPainter oldDelegate) {
    return oldDelegate.camera != camera ||
        !identical(oldDelegate.geometry, geometry);
  }
}

/// Build cost helper for benchmarks: project + path for every hex vertex.
int benchmarkBatchPathBuild({
  required List<CoverageBatchHex> hexes,
  required Offset Function(LatLng) project,
}) {
  var ops = 0;
  final path = Path();
  for (final hex in hexes) {
    if (hex.points.length < 3) continue;
    final first = project(hex.points.first);
    path.moveTo(first.dx, first.dy);
    ops++;
    for (var i = 1; i < hex.points.length; i++) {
      final o = project(hex.points[i]);
      path.lineTo(o.dx, o.dy);
      ops++;
    }
    path.close();
  }
  // Touch path so it is not optimized away.
  for (final _ in path.computeMetrics()) {
    ops++;
  }
  return ops;
}
