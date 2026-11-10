import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/widgets/coverage_hex_batch_layer.dart';

List<LatLng> _squareAround(LatLng center, {double d = 0.01}) {
  return [
    LatLng(center.latitude - d, center.longitude - d),
    LatLng(center.latitude - d, center.longitude + d),
    LatLng(center.latitude + d, center.longitude + d),
    LatLng(center.latitude + d, center.longitude - d),
  ];
}

void main() {
  group('pointInLatLngRing', () {
    test('detects interior and exterior points', () {
      final ring = _squareAround(const LatLng(10, 20));
      expect(pointInLatLngRing(const LatLng(10, 20), ring), isTrue);
      expect(pointInLatLngRing(const LatLng(10.005, 20.005), ring), isTrue);
      expect(pointInLatLngRing(const LatLng(12, 22), ring), isFalse);
    });
  });

  group('hitTestCoverageBatchHexes', () {
    test('returns top-most hex when rings overlap', () {
      final lower = CoverageBatchHex(
        points: _squareAround(const LatLng(0, 0), d: 0.05),
        hitId: 'lower',
        fill: const Color(0x110000FF),
        border: const Color(0xFF0000FF),
      );
      final upper = CoverageBatchHex(
        points: _squareAround(const LatLng(0, 0), d: 0.02),
        hitId: 'upper',
        fill: const Color(0x11FF0000),
        border: const Color(0xFFFF0000),
      );
      expect(
        hitTestCoverageBatchHexes(const LatLng(0, 0), [lower, upper]),
        'upper',
      );
      expect(
        hitTestCoverageBatchHexes(const LatLng(0.04, 0), [lower, upper]),
        'lower',
      );
      expect(
        hitTestCoverageBatchHexes(const LatLng(1, 1), [lower, upper]),
        isNull,
      );
    });

    test('real hex ring misses points outside the cell', () {
      const center = LatLng(40.79, -77.86);
      final ring = getHexVertices(center.latitude, center.longitude);
      final hex = CoverageBatchHex(
        points: ring,
        hitId: 'cell',
        fill: const Color(0x4433AA55),
        border: const Color(0xFF33AA55),
      );
      expect(hitTestCoverageBatchHexes(center, [hex]), 'cell');
      // Just outside each edge midpoint, and far away on the same latitude
      // (the ray-cast direction). None of these may count as a hit.
      for (var i = 0; i < ring.length; i++) {
        final a = ring[i];
        final b = ring[(i + 1) % ring.length];
        final mid = LatLng(
          (a.latitude + b.latitude) / 2,
          (a.longitude + b.longitude) / 2,
        );
        final outside = LatLng(
          mid.latitude + (mid.latitude - center.latitude) * 0.15,
          mid.longitude + (mid.longitude - center.longitude) * 0.15,
        );
        expect(
          hitTestCoverageBatchHexes(outside, [hex]),
          isNull,
          reason: 'edge $i $outside',
        );
      }
      expect(
        hitTestCoverageBatchHexes(
          LatLng(center.latitude, center.longitude + 1),
          [hex],
        ),
        isNull,
      );
      expect(
        hitTestCoverageBatchHexes(
          LatLng(center.latitude, center.longitude - 1),
          [hex],
        ),
        isNull,
      );
    });

    test('non-finite tap is a miss', () {
      final hex = CoverageBatchHex(
        points: _squareAround(const LatLng(0, 0)),
        hitId: 'cell',
        fill: const Color(0x4433AA55),
        border: const Color(0xFF33AA55),
      );
      expect(
        hitTestCoverageBatchHexes(const LatLng(double.nan, 0), [hex]),
        isNull,
      );
    });

    test('screen hit matches the painted ring and misses empty pixels', () {
      final hex = CoverageBatchHex(
        points: _squareAround(const LatLng(10, 20), d: 1),
        hitId: 'cell',
        fill: const Color(0x4433AA55),
        border: const Color(0xFF33AA55),
      );
      Offset project(LatLng point) =>
          Offset(point.longitude * 10, point.latitude * 10);
      expect(
        hitTestCoverageBatchHexesOnScreen(project(const LatLng(10, 20)), [
          hex,
        ], project),
        'cell',
      );
      expect(
        hitTestCoverageBatchHexesOnScreen(const Offset(0, 0), [hex], project),
        isNull,
      );
      // A geographic hit must not be implied by a previous selection. The
      // screen point is empty even if a caller still has a selected id.
      expect(
        hitTestCoverageBatchHexesOnScreen(const Offset(5000, 5000), [
          hex,
        ], project),
        isNull,
      );
    });

    test('preserves one hit id per hex (no merge)', () {
      final hexes = <CoverageBatchHex>[
        for (var i = 0; i < 64; i++)
          CoverageBatchHex(
            points: _squareAround(LatLng(i * 0.03, i * 0.03), d: 0.01),
            hitId: 'hex-$i',
            fill: const Color(0x4433AA55),
            border: const Color(0xFF33AA55),
          ),
      ];
      expect(hexes.length, 64);
      for (var i = 0; i < 64; i++) {
        expect(
          hitTestCoverageBatchHexes(LatLng(i * 0.03, i * 0.03), hexes),
          'hex-$i',
        );
      }
    });
  });

  group('batch draw cost', () {
    test('path build scales with hex vertex count (no drop)', () {
      CoverageBatchHex makeHex(int i) => CoverageBatchHex(
        points: [
          LatLng(i * 0.001, 0),
          LatLng(i * 0.001, 0.001),
          LatLng(i * 0.001 + 0.001, 0.001),
          LatLng(i * 0.001 + 0.001, 0),
          LatLng(i * 0.001 + 0.0005, -0.0005),
          LatLng(i * 0.001, 0),
        ],
        hitId: 'h$i',
        fill: const Color(0x4433AA55),
        border: const Color(0xFF33AA55),
      );

      Offset project(LatLng ll) =>
          Offset(ll.longitude * 100000, -ll.latitude * 100000);

      final small = [for (var i = 0; i < 100; i++) makeHex(i)];
      final dense = [for (var i = 0; i < 1000; i++) makeHex(i)];

      final sw = Stopwatch()..start();
      final smallOps = benchmarkBatchPathBuild(hexes: small, project: project);
      final smallMs = sw.elapsedMilliseconds;
      sw
        ..reset()
        ..start();
      final denseOps = benchmarkBatchPathBuild(hexes: dense, project: project);
      final denseMs = sw.elapsedMilliseconds;

      // Every hex contributes its vertices — count must grow ~10x.
      expect(denseOps, greaterThan(smallOps * 8));
      expect(smallOps, greaterThan(100));
      // Host smoke bound only; keep generous so CI noise doesn't flake.
      expect(denseMs, lessThan(5000));
      expect(smallMs, lessThan(2000));
    });
  });
}
