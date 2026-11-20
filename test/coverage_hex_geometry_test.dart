import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:mesh_utility/src/widgets/coverage_hex_batch_layer.dart';

MapCamera _camera({
  LatLng center = const LatLng(40.7934, -77.86),
  required double zoom,
  double rotation = 0,
  Size size = const Size(400, 800),
}) {
  return MapCamera(
    crs: const Epsg3857(),
    center: center,
    zoom: zoom,
    rotation: rotation,
    nonRotatedSize: size,
  );
}

/// Flat-topped test hex around [c] with radius [r] degrees.
CoverageBatchHex _hex(LatLng c, String id, {double r = 0.004}) {
  return CoverageBatchHex(
    points: [
      LatLng(c.latitude, c.longitude - r),
      LatLng(c.latitude + r * 0.85, c.longitude - r / 2),
      LatLng(c.latitude + r * 0.85, c.longitude + r / 2),
      LatLng(c.latitude, c.longitude + r),
      LatLng(c.latitude - r * 0.85, c.longitude + r / 2),
      LatLng(c.latitude - r * 0.85, c.longitude - r / 2),
    ],
    hitId: id,
    fill: const Color(0xFF22C55E),
    border: const Color(0xFF22C55E),
  );
}

class _CountingCanvas implements Canvas {
  int paths = 0;

  @override
  void drawPath(Path path, Paint paint) => paths++;

  @override
  void save() {}

  @override
  void restore() {}

  @override
  void translate(double dx, double dy) {}

  @override
  void scale(double sx, [double? sy]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('CoverageHexGeometry transform', () {
    test('cached rings land exactly where per-frame projection puts them', () {
      const points = <LatLng>[
        LatLng(40.80, -77.87),
        LatLng(40.7934, -77.86),
        LatLng(40.95, -77.40),
        LatLng(40.30, -78.20),
      ];
      final ref = _camera(zoom: 10.4);
      final geometry = CoverageHexGeometry.build([
        _hex(points.first, 'a'),
      ], ref);
      final cameras = <MapCamera>[
        _camera(zoom: 10.4),
        _camera(center: const LatLng(40.9, -77.5), zoom: 10.4),
        _camera(center: const LatLng(40.6, -78.0), zoom: 11.7),
        _camera(center: const LatLng(40.8, -77.9), zoom: 7.6, rotation: 33),
        _camera(zoom: 11.9, rotation: -120),
      ];
      for (final camera in cameras) {
        for (final p in points) {
          final local = coverageHexLayerOffset(ref, p);
          final painted = geometry.toLayer(local, camera);
          final direct = coverageHexLayerOffset(camera, p);
          expect(
            (painted - direct).distance,
            lessThan(1e-6),
            reason: 'zoom=${camera.zoom} center=${camera.center}',
          );
        }
      }
    });

    test('rebuilds for a new hex list or a large zoom change only', () {
      final hexes = [_hex(const LatLng(40.8, -77.9), 'a')];
      final ref = _camera(zoom: 10);
      final geometry = CoverageHexGeometry.build(hexes, ref);
      expect(geometry.reusableFor(hexes, ref), isTrue);
      expect(
        geometry.reusableFor(hexes, _camera(zoom: 11.4, rotation: 20)),
        isTrue,
      );
      expect(geometry.reusableFor(hexes, _camera(zoom: 7.2)), isTrue);
      expect(geometry.reusableFor(hexes, _camera(zoom: 11.6)), isFalse);
      expect(geometry.reusableFor(hexes, _camera(zoom: 6.9)), isFalse);
      expect(geometry.reusableFor([...hexes], ref), isFalse);
    });
  });

  group('CoverageHexGeometry paint', () {
    test('only buckets near the viewport are drawn', () {
      final near = [
        for (var i = 0; i < 20; i++)
          _hex(LatLng(40.79 + i * 0.002, -77.86), 'n$i'),
      ];
      final far = [
        for (var i = 0; i < 20; i++)
          _hex(LatLng(34.0 + i * 0.002, -118.2), 'f$i'),
      ];
      final ref = _camera(zoom: 10);
      final geometry = CoverageHexGeometry.build([...near, ...far], ref);
      expect(geometry.bucketCount, greaterThanOrEqualTo(2));

      final canvas = _CountingCanvas();
      geometry.paint(canvas, ref.size, ref);
      // One fill + one border path per color for the near bucket(s) only.
      expect(canvas.paths, greaterThan(0));
      expect(canvas.paths, lessThan(geometry.bucketCount * 2));

      final empty = _CountingCanvas();
      final ocean = _camera(center: const LatLng(0, -30), zoom: 10);
      geometry.paint(empty, ocean.size, ocean);
      expect(empty.paths, 0);
    });

    testWidgets('every hex is painted at its true position (no drop)', (
      tester,
    ) async {
      final hexes = [
        for (var r = 0; r < 6; r++)
          for (var c = 0; c < 6; c++)
            _hex(
              LatLng(40.70 + r * 0.03, -78.00 + c * 0.05),
              'h$r-$c',
              r: 0.006,
            ),
      ];
      final ref = _camera(zoom: 10.5, size: const Size(600, 600));
      final geometry = CoverageHexGeometry.build(hexes, ref);
      for (final camera in [
        ref,
        _camera(
          center: const LatLng(40.78, -77.88),
          zoom: 11.2,
          size: const Size(600, 600),
        ),
        _camera(
          center: const LatLng(40.76, -77.84),
          zoom: 9.6,
          size: const Size(600, 600),
        ),
      ]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        geometry.paint(canvas, camera.size, camera);
        final picture = recorder.endRecording();
        final bytes = await tester.runAsync(() async {
          final image = await picture.toImage(600, 600);
          final data = await image.toByteData();
          image.dispose();
          return data!;
        });
        picture.dispose();
        var checked = 0;
        for (final hex in hexes) {
          var sumLat = 0.0;
          var sumLng = 0.0;
          for (final p in hex.points) {
            sumLat += p.latitude;
            sumLng += p.longitude;
          }
          final center = LatLng(
            sumLat / hex.points.length,
            sumLng / hex.points.length,
          );
          final o = coverageHexLayerOffset(camera, center);
          final x = o.dx.round();
          final y = o.dy.round();
          if (x < 0 || y < 0 || x >= 600 || y >= 600) continue;
          final alpha = bytes!.getUint8((y * 600 + x) * 4 + 3);
          expect(alpha, greaterThan(0), reason: '${hex.hitId} @ $x,$y');
          checked++;
        }
        expect(checked, greaterThan(10));
      }
    });
  });

  group('CoverageHexGeometry update', () {
    test('in-view refresh reuses unchanged buckets and stays exact', () {
      final near = [
        for (var i = 0; i < 30; i++)
          _hex(LatLng(40.70 + (i ~/ 6) * 0.01, -78.0 + (i % 6) * 0.01), 'n$i'),
      ];
      final east = [
        for (var i = 0; i < 30; i++)
          _hex(LatLng(40.70 + (i ~/ 6) * 0.01, -77.4 + (i % 6) * 0.01), 'e$i'),
      ];
      final ref = _camera(center: const LatLng(40.72, -77.97), zoom: 11);
      final first = CoverageHexGeometry.build(near, ref);
      // Pan east: the new in-view list keeps the near hexes (same objects)
      // and adds the east ones.
      final moved = _camera(center: const LatLng(40.72, -77.7), zoom: 11.4);
      final next = CoverageHexGeometry.update(first, [...near, ...east], moved);
      expect(next.refZoom, first.refZoom);
      expect(next.refOrigin, first.refOrigin);
      expect(next.reusedBucketCount, first.bucketCount);
      expect(next.bucketCount, greaterThan(first.bucketCount));
      for (final p in [near.first.points.first, east.last.points[2]]) {
        final local =
            const Epsg3857().latLngToOffset(p, next.refZoom) - next.refOrigin;
        expect(
          (next.toLayer(local, moved) - coverageHexLayerOffset(moved, p))
              .distance,
          lessThan(1e-6),
        );
      }
    });

    test('large zoom change starts a new reference frame', () {
      final hexes = [_hex(const LatLng(40.8, -77.9), 'a')];
      final ref = _camera(zoom: 10);
      final first = CoverageHexGeometry.build(hexes, ref);
      final far = _camera(zoom: 12.5);
      final next = CoverageHexGeometry.update(first, [...hexes], far);
      expect(next.refZoom, 12.5);
      expect(next.reusedBucketCount, 0);
    });

    test('mid-gesture zoom stays usable, settles past the soft range', () {
      final hexes = [_hex(const LatLng(40.8, -77.9), 'a')];
      final geometry = CoverageHexGeometry.build(hexes, _camera(zoom: 10));
      final pinch = _camera(zoom: 13);
      expect(geometry.usableFor(pinch), isTrue);
      expect(geometry.settledFor(pinch), isFalse);
      expect(geometry.usableFor(_camera(zoom: 15.5)), isFalse);
      expect(geometry.settledFor(_camera(zoom: 11)), isTrue);
    });
  });
}
