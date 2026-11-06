import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/grid.dart';

void main() {
  group('snapToHexGrid', () {
    test('origin snaps to origin', () {
      final result = snapToHexGrid(0.0, 0.0);
      expect(result.snapLat, closeTo(0.0, 1e-9));
      expect(result.snapLng, closeTo(0.0, 1e-9));
    });

    test('nearby points snap to same cell', () {
      // Use two points only ~1 m apart — guaranteed same hex cell.
      final a = snapToHexGrid(37.7749, -122.4194);
      final b = snapToHexGrid(37.77491, -122.41941);
      expect(a.snapLat, equals(b.snapLat));
      expect(a.snapLng, equals(b.snapLng));
    });

    test('snapped lat is a multiple of rowSpacing', () {
      final result = snapToHexGrid(34.0522, -118.2437);
      final row = (result.snapLat / rowSpacing).round();
      expect(result.snapLat, closeTo(row * rowSpacing, 1e-9));
    });
  });

  group('hexKey', () {
    test('same location produces same key', () {
      final k1 = hexKey(37.7749, -122.4194);
      final k2 = hexKey(37.7749, -122.4194);
      expect(k1, equals(k2));
    });

    test('different locations produce different keys', () {
      final k1 = hexKey(37.7749, -122.4194);
      final k2 = hexKey(40.7128, -74.0060);
      expect(k1, isNot(equals(k2)));
    });

    test('key format contains colon separator', () {
      final k = hexKey(0.0, 0.0);
      expect(k, contains(':'));
    });
  });

  group('getHexVertices', () {
    test('returns exactly 6 vertices', () {
      final verts = getHexVertices(37.7749, -122.4194);
      expect(verts.length, equals(6));
    });

    test('vertices are near the centre', () {
      const lat = 37.7749;
      const lng = -122.4194;
      final verts = getHexVertices(lat, lng);
      for (final v in verts) {
        expect((v.latitude - lat).abs(), lessThan(hexSize * 2));
        expect((v.longitude - lng).abs(), lessThan(hexSize * lngScale * 2));
      }
    });
  });

  group('distanceMiles', () {
    test('same point is zero distance', () {
      expect(distanceMiles(37.0, -122.0, 37.0, -122.0), closeTo(0.0, 1e-9));
    });

    test('one degree latitude is roughly 69 miles', () {
      final d = distanceMiles(0.0, 0.0, 1.0, 0.0);
      expect(d, closeTo(69.0, 1.0));
    });

    test('known city pair is reasonable', () {
      // San Francisco to Los Angeles ~347 miles.
      final d = distanceMiles(37.7749, -122.4194, 34.0522, -118.2437);
      expect(d, closeTo(347.0, 10.0));
    });
  });
}
