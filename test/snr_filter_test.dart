import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/snr_filter.dart';

CoverageZone _zone({
  double? snr,
  bool dead = false,
  double? rssi,
  String id = 'z',
}) {
  return CoverageZone(
    id: id,
    centerLat: 0,
    centerLng: 0,
    radiusMeters: 100,
    avgRssi: dead ? null : (rssi ?? -90),
    avgSnr: snr,
    scanCount: 1,
    lastScanned: DateTime.utc(2026, 1, 1),
    isDeadZone: dead,
    polygon: const [],
  );
}

void main() {
  group('preset bands', () {
    test('Weak is avgSnr <= -7', () {
      const filter = SnrFilter.weak;
      expect(filter.matches(_zone(snr: -7)), isTrue);
      expect(filter.matches(_zone(snr: -7.0)), isTrue);
      expect(filter.matches(_zone(snr: -13)), isTrue);
      expect(filter.matches(_zone(snr: -6.999)), isFalse);
      expect(filter.matches(_zone(snr: 0)), isFalse);
      expect(filter.matches(_zone(snr: 1)), isFalse);
    });

    test('OK is -7 < avgSnr <= 0', () {
      const filter = SnrFilter.ok;
      expect(filter.matches(_zone(snr: -7)), isFalse);
      expect(filter.matches(_zone(snr: -6.999)), isTrue);
      expect(filter.matches(_zone(snr: -0.1)), isTrue);
      expect(filter.matches(_zone(snr: 0)), isTrue);
      expect(filter.matches(_zone(snr: 0.0)), isTrue);
      expect(filter.matches(_zone(snr: 0.0001)), isFalse);
    });

    test('Strong is avgSnr > 0', () {
      const filter = SnrFilter.strong;
      expect(filter.matches(_zone(snr: 0)), isFalse);
      expect(filter.matches(_zone(snr: 0.0001)), isTrue);
      expect(filter.matches(_zone(snr: 5)), isTrue);
      expect(filter.matches(_zone(snr: 10)), isTrue);
      expect(filter.matches(_zone(snr: -1)), isFalse);
    });

    test('All matches every zone including dead and null SNR', () {
      const filter = SnrFilter.all;
      expect(filter.active, isFalse);
      expect(filter.matches(_zone(snr: 5)), isTrue);
      expect(filter.matches(_zone(snr: null)), isTrue);
      expect(filter.matches(_zone(dead: true)), isTrue);
    });
  });

  group('custom ranges', () {
    test('inclusive both bounds', () {
      final filter = SnrFilter.custom(min: -5, max: 0);
      expect(filter.matches(_zone(snr: -5)), isTrue);
      expect(filter.matches(_zone(snr: 0)), isTrue);
      expect(filter.matches(_zone(snr: -5.1)), isFalse);
      expect(filter.matches(_zone(snr: 0.1)), isFalse);
      expect(filter.matches(_zone(snr: -2)), isTrue);
    });

    test('one-sided min', () {
      final filter = SnrFilter.custom(min: -5);
      expect(filter.max, isNull);
      expect(filter.matches(_zone(snr: -5)), isTrue);
      expect(filter.matches(_zone(snr: 15)), isTrue);
      expect(filter.matches(_zone(snr: -5.1)), isFalse);
    });

    test('one-sided max', () {
      final filter = SnrFilter.custom(max: 0);
      expect(filter.min, isNull);
      expect(filter.matches(_zone(snr: 0)), isTrue);
      expect(filter.matches(_zone(snr: -20)), isTrue);
      expect(filter.matches(_zone(snr: 0.1)), isFalse);
    });

    test('unbounded custom keeps any non-dead SNR', () {
      final filter = SnrFilter.custom();
      expect(filter.active, isTrue);
      expect(filter.matches(_zone(snr: -20)), isTrue);
      expect(filter.matches(_zone(snr: 15)), isTrue);
      expect(filter.matches(_zone(snr: null)), isFalse);
      expect(filter.matches(_zone(dead: true)), isFalse);
    });

    test('swaps min and max when reversed', () {
      final filter = SnrFilter.custom(min: 5, max: -5);
      expect(filter.min, -5);
      expect(filter.max, 5);
    });
  });

  group('null SNR and dead zones', () {
    test('active presets hide null SNR and dead zones', () {
      for (final filter in <SnrFilter>[
        SnrFilter.weak,
        SnrFilter.ok,
        SnrFilter.strong,
        SnrFilter.custom(min: -20, max: 15),
      ]) {
        expect(filter.matches(_zone(snr: null)), isFalse, reason: '$filter');
        expect(filter.matches(_zone(dead: true)), isFalse, reason: '$filter');
        expect(
          filter.matches(_zone(snr: -10, dead: true)),
          isFalse,
          reason: '$filter',
        );
      }
    });
  });

  group('clamping', () {
    test('custom bounds clamp to -20..15', () {
      final filter = SnrFilter.custom(min: -100, max: 40);
      expect(filter.min, kSnrFilterMinDb);
      expect(filter.max, kSnrFilterMaxDb);
      expect(clampSnrFilterBound(-100), -20);
      expect(clampSnrFilterBound(40), 15);
      expect(clampSnrFilterBound(-20), -20);
      expect(clampSnrFilterBound(15), 15);
      expect(clampSnrFilterBound(null), isNull);
      expect(clampSnrFilterBound(double.nan), isNull);
    });
  });

  group('labels', () {
    test('preset and custom labels', () {
      expect(SnrFilter.weak.label, 'SNR: Weak');
      expect(SnrFilter.ok.label, 'SNR: OK');
      expect(SnrFilter.strong.label, 'SNR: Strong');
      expect(SnrFilter.all.label, 'SNR: All');
      expect(SnrFilter.custom(min: -5, max: 0).label, 'SNR: -5 to 0 dB');
      expect(SnrFilter.custom(min: -5).label, 'SNR: ≥ -5 dB');
      expect(SnrFilter.custom(max: 0).label, 'SNR: ≤ 0 dB');
      expect(SnrFilter.custom().label, 'SNR: Custom');
    });
  });

  group('serialization', () {
    test('preset encode/decode roundtrip', () {
      for (final filter in const [
        SnrFilter.all,
        SnrFilter.weak,
        SnrFilter.ok,
        SnrFilter.strong,
      ]) {
        expect(SnrFilter.decode(filter.encode()), filter);
        expect(SnrFilter.fromJson(filter.toJson()), filter);
      }
    });

    test('custom encode/decode and JSON roundtrip', () {
      final both = SnrFilter.custom(min: -5, max: 0);
      expect(both.encode(), 'custom:-5:0');
      expect(SnrFilter.decode(both.encode()), both);
      expect(SnrFilter.fromJson(both.toJson()), both);

      final minOnly = SnrFilter.custom(min: -5);
      expect(minOnly.encode(), 'custom:-5:');
      expect(SnrFilter.decode(minOnly.encode()), minOnly);

      final maxOnly = SnrFilter.custom(max: 0);
      expect(maxOnly.encode(), 'custom::0');
      expect(SnrFilter.decode(maxOnly.encode()), maxOnly);

      expect(SnrFilter.decode('{"preset":"weak"}'), SnrFilter.weak);
      expect(
        SnrFilter.decode('{"preset":"custom","min":-5,"max":0}'),
        SnrFilter.custom(min: -5, max: 0),
      );
      expect(SnrFilter.decode(null), SnrFilter.all);
      expect(SnrFilter.decode(''), SnrFilter.all);
      expect(SnrFilter.decode('nope'), SnrFilter.all);
    });

    test('decode clamps custom bounds', () {
      final filter = SnrFilter.decode('custom:-100:50');
      expect(filter.min, -20);
      expect(filter.max, 15);
    });
  });

  group('applySnrFilter', () {
    test('inactive filter returns the same list instance', () {
      final zones = <CoverageZone>[_zone(snr: 5), _zone(dead: true, id: 'd')];
      expect(identical(applySnrFilter(SnrFilter.all, zones), zones), isTrue);
    });

    test('active filter is a single pass that drops dead and non-matching', () {
      final weak = _zone(snr: -10, id: 'w');
      final ok = _zone(snr: -3, id: 'o');
      final strong = _zone(snr: 4, id: 's');
      final dead = _zone(dead: true, id: 'd');
      final zones = <CoverageZone>[weak, ok, strong, dead];
      expect(applySnrFilter(SnrFilter.weak, zones), [weak]);
      expect(applySnrFilter(SnrFilter.ok, zones), [ok]);
      expect(applySnrFilter(SnrFilter.strong, zones), [strong]);
    });
  });
}
