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
    this.dashed = false,
  });

  final List<LatLng> points;
  final String hitId;
  final Color fill;
  final Color border;
  final bool dashed;
}

/// Batched coverage paint for flutter_map. One [CustomPainter] draws every
/// hex fill/border; hit-testing is done by the map page via
/// [hitTestCoverageBatchHexes] so pan/zoom stay with FlutterMap.
class CoverageHexBatchLayer extends StatelessWidget {
  const CoverageHexBatchLayer({super.key, required this.hexes});

  final List<CoverageBatchHex> hexes;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return MobileLayerTransformer(
      child: CustomPaint(
        size: camera.size,
        painter: _CoverageHexBatchPainter(camera: camera, hexes: hexes),
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

class _CoverageHexBatchPainter extends CustomPainter {
  _CoverageHexBatchPainter({required this.camera, required this.hexes});

  final MapCamera camera;
  final List<CoverageBatchHex> hexes;

  @override
  void paint(Canvas canvas, Size size) {
    if (hexes.isEmpty) return;

    // Batch fills by identical color to cut draw calls while keeping every
    // hex vertex (no merge of geometry).
    final fillsByColor = <Color, Path>{};
    final solidBorders = <Color, Path>{};
    final dashed = <CoverageBatchHex>[];

    for (final hex in hexes) {
      if (hex.points.length < 3) continue;
      final path = Path();
      final first = coverageHexLayerOffset(camera, hex.points.first);
      path.moveTo(first.dx, first.dy);
      for (var i = 1; i < hex.points.length; i++) {
        final o = coverageHexLayerOffset(camera, hex.points[i]);
        path.lineTo(o.dx, o.dy);
      }
      path.close();

      fillsByColor.update(
        hex.fill,
        (existing) => existing..addPath(path, Offset.zero),
        ifAbsent: () => Path()..addPath(path, Offset.zero),
      );

      if (hex.dashed) {
        dashed.add(hex);
      } else {
        solidBorders.update(
          hex.border,
          (existing) => existing..addPath(path, Offset.zero),
          ifAbsent: () => Path()..addPath(path, Offset.zero),
        );
      }
    }

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final entry in fillsByColor.entries) {
      fillPaint.color = entry.key;
      canvas.drawPath(entry.value, fillPaint);
    }

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..isAntiAlias = true;
    for (final entry in solidBorders.entries) {
      borderPaint.color = entry.key;
      canvas.drawPath(entry.value, borderPaint);
    }

    // Dashed borders (dead zones) — still one path per hex, not merged cells.
    for (final hex in dashed) {
      final path = Path();
      final first = coverageHexLayerOffset(camera, hex.points.first);
      path.moveTo(first.dx, first.dy);
      for (var i = 1; i < hex.points.length; i++) {
        final o = coverageHexLayerOffset(camera, hex.points[i]);
        path.lineTo(o.dx, o.dy);
      }
      path.close();
      borderPaint.color = hex.border;
      borderPaint.strokeWidth = 1;
      canvas.drawPath(
        _dashPath(path, dashLength: 6, gapLength: 4),
        borderPaint,
      );
    }
  }

  Path _dashPath(
    Path source, {
    required double dashLength,
    required double gapLength,
  }) {
    final metrics = source.computeMetrics();
    final out = Path();
    for (final metric in metrics) {
      var distance = 0.0;
      var draw = true;
      while (distance < metric.length) {
        final len = draw ? dashLength : gapLength;
        final next = (distance + len).clamp(0.0, metric.length);
        if (draw) {
          out.addPath(metric.extractPath(distance, next), Offset.zero);
        }
        distance = next;
        draw = !draw;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(covariant _CoverageHexBatchPainter oldDelegate) {
    return oldDelegate.camera != camera ||
        !identical(oldDelegate.hexes, hexes) ||
        oldDelegate.hexes.length != hexes.length;
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
