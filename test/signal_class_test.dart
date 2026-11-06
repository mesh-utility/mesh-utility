import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/services/signal_class.dart';

void main() {
  group('signalClassForValues', () {
    test('Dead Zone only when there is no response at all', () {
      final dead = signalClassForValues(rssi: null, snr: null);
      expect(dead.label, 'Dead Zone');
      expect(dead.level, 0);
    });

    test('user example RSSI -123 SNR -6.8 is Poor, not Dead Zone', () {
      final cls = signalClassForValues(rssi: -123, snr: -6.8);
      expect(cls.label, isNot('Dead Zone'));
      expect(cls.label, 'Poor');
      expect(cls.level, greaterThan(0));
    });

    test('very weak RSSI alone is Poor, not Dead Zone', () {
      expect(signalClassForValues(rssi: -130, snr: null).label, 'Poor');
      expect(signalClassForValues(rssi: -120, snr: 5).label, 'Poor');
    });

    test('legend tiers', () {
      expect(signalClassForValues(rssi: -80, snr: 12).label, 'Excellent');
      expect(signalClassForValues(rssi: -95, snr: 5).label, 'Good');
      expect(signalClassForValues(rssi: -105, snr: -3).label, 'Fair');
      expect(signalClassForValues(rssi: -112, snr: -10).label, 'Marginal');
      expect(signalClassForValues(rssi: -118, snr: -10).label, 'Poor');
    });

    test('Noisy when good RSSI and bad SNR', () {
      final noisy = signalClassForValues(rssi: -85, snr: -15);
      expect(noisy.label, 'Noisy');
      expect(noisy.color, kNoisySignalColor);
    });

    test('includeDeadZone false maps no-response to Poor', () {
      expect(
        signalClassForValues(
          rssi: null,
          snr: null,
          includeDeadZone: false,
        ).label,
        'Poor',
      );
    });
  });

  group('deadZoneFromMetrics / CoverageZone.fromJson', () {
    test('stored dead flag cleared when averages show a response', () {
      expect(
        deadZoneFromMetrics(
          avgRssi: -123,
          avgSnr: -6.8,
          storedFlag: true,
        ),
        isFalse,
      );
    });

    test('no averages with stored dead stays dead', () {
      expect(
        deadZoneFromMetrics(
          avgRssi: null,
          avgSnr: null,
          storedFlag: true,
        ),
        isTrue,
      );
    });

    test('fromJson reclassifies legacy dead rows that have RSSI', () {
      final zone = CoverageZone.fromJson({
        'id': 'hex1',
        'centerLat': 1.0,
        'centerLng': 2.0,
        'radiusMeters': 100,
        'avgRssi': -123,
        'avgSnr': -6.8,
        'scanCount': 1,
        'lastScanned': '2026-11-06T00:00:00.000Z',
        'isDeadZone': true,
        'polygon': [],
      });
      expect(zone.isDeadZone, isFalse);
      expect(signalClassForValues(rssi: zone.avgRssi, snr: zone.avgSnr).label,
          isNot('Dead Zone'));
    });

    test('fromJson keeps true dead zones with no metrics', () {
      final zone = CoverageZone.fromJson({
        'id': 'hex2',
        'centerLat': 1.0,
        'centerLng': 2.0,
        'avgRssi': null,
        'avgSnr': null,
        'scanCount': 1,
        'lastScanned': '2026-11-06T00:00:00.000Z',
        'isDeadZone': true,
        'polygon': [],
      });
      expect(zone.isDeadZone, isTrue);
    });
  });

  group('signalLevelForValues', () {
    test('both null is level 0; any metric floors above 0', () {
      expect(signalLevelForValues(rssi: null, snr: null), 0);
      expect(signalLevelForValues(rssi: -123, snr: -6.8), greaterThan(0));
      expect(signalLevelForValues(rssi: -140, snr: -20), 1);
    });
  });
}
