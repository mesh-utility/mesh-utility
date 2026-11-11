import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/widgets/coverage_hex_batch_layer.dart';

MapCamera _camera({
  required double zoom,
  required double rotation,
  Size size = const Size(400, 800),
}) {
  return MapCamera(
    crs: const Epsg3857(),
    center: const LatLng(40.7934, -77.86),
    zoom: zoom,
    rotation: rotation,
    nonRotatedSize: size,
  );
}

void main() {
  const corner = LatLng(40.80, -77.87);
  const cellCenter = LatLng(40.7934, -77.86);

  group('coverage hex projection vs PolygonLayer', () {
    test('latLngToScreenOffset drifts from PolygonLayer under zoom + rotation', () {
      // This is the Alpha-25 bug: painter used latLngToScreenOffset (already
      // rotated, different origin) inside MobileLayerTransformer, which
      // rotates again. Confirm that method does not match PolygonLayer.
      final camera = _camera(zoom: 11.3, rotation: 12);
      final polygonOffset = camera.getOffsetFromOrigin(corner);
      final screenOffset = camera.latLngToScreenOffset(corner);
      final drift = (screenOffset - polygonOffset).distance;
      expect(
        drift,
        greaterThan(8),
        reason: 'expected a visible pixel drift, got $drift',
      );
    });

    test('layer offsets match PolygonLayer at many zooms and rotations', () {
      const zooms = <double>[8, 9.5, 11, 12.25, 14];
      const rotations = <double>[0, 2.5, 12, 45, -17.5, 180];
      for (final zoom in zooms) {
        for (final rotation in rotations) {
          final camera = _camera(zoom: zoom, rotation: rotation);
          final painted = coverageHexLayerOffset(camera, corner);
          final polygon = camera.getOffsetFromOrigin(corner);
          expect(
            (painted - polygon).distance,
            lessThan(1e-9),
            reason: 'zoom=$zoom rotation=$rotation painted=$painted polygon=$polygon',
          );
        }
      }
    });

    test('without rotation, layer offsets stay finite and near the view', () {
      final camera = _camera(zoom: 12, rotation: 0);
      final painted = coverageHexLayerOffset(camera, cellCenter);
      expect(painted.dx.isFinite, isTrue);
      expect(painted.dy.isFinite, isTrue);
      // The map center projects near the layer origin's mid-point.
      expect(
        (painted - camera.size.center(Offset.zero)).distance,
        lessThan(1),
      );
    });

    test('screen taps convert into the painted ring under rotation', () {
      final camera = _camera(zoom: 12, rotation: 18);
      final ring = getHexVertices(cellCenter.latitude, cellCenter.longitude);
      final hex = CoverageBatchHex(
        points: ring,
        hitId: 'cell',
        fill: const Color(0x4433AA55),
        border: const Color(0xFF33AA55),
      );
      Offset project(LatLng p) => coverageHexLayerOffset(camera, p);
      final layerPoint = project(cellCenter);
      final screenPoint = camera.rotatePoint(
        camera.size.center(Offset.zero),
        layerPoint,
        counterRotation: false,
      );
      final back = coverageHexScreenToLayer(camera, screenPoint);
      expect((back - layerPoint).distance, lessThan(0.01));
      expect(
        hitTestCoverageBatchHexesOnScreen(back, [hex], project),
        'cell',
      );
      // A screen tap far from the hex must miss in layer space too.
      expect(
        hitTestCoverageBatchHexesOnScreen(
          coverageHexScreenToLayer(camera, const Offset(4, 4)),
          [hex],
          project,
        ),
        isNull,
      );
    });

    test('rotation keeps true-size hex corners on the same geographic ring', () {
      // Corners are projected, not resized or merged, when the camera zooms
      // or rotates — only the layer-space offset changes with the camera.
      final ring = getHexVertices(cellCenter.latitude, cellCenter.longitude);
      final atRest = _camera(zoom: 11, rotation: 0);
      final zoomed = _camera(zoom: 13.5, rotation: 22);
      expect(ring.length, 6);
      for (final point in ring) {
        final a = coverageHexLayerOffset(atRest, point);
        final b = coverageHexLayerOffset(zoomed, point);
        expect(a.dx.isFinite && a.dy.isFinite, isTrue);
        expect(b.dx.isFinite && b.dy.isFinite, isTrue);
        expect((a - b).distance, greaterThan(1));
      }
      // Distances between opposite corners scale with zoom, not with rotation.
      final unrotatedZoomed = _camera(zoom: 13.5, rotation: 0);
      final widthAtRest = _ringWidth(atRest, ring);
      final widthZoomed = _ringWidth(zoomed, ring);
      final widthZoomedUnrotated = _ringWidth(unrotatedZoomed, ring);
      expect(widthZoomed, closeTo(widthZoomedUnrotated, 1e-6));
      final expectedScale = math.pow(2, 13.5 - 11);
      expect(widthZoomed / widthAtRest, closeTo(expectedScale, 0.05));
    });
  });
}

double _ringWidth(MapCamera camera, List<LatLng> ring) {
  final xs = ring.map((p) => coverageHexLayerOffset(camera, p).dx).toList();
  return xs.reduce(math.max) - xs.reduce(math.min);
}
