import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/scan_cache_area.dart';
import 'package:mesh_utility/src/services/settings_store.dart';

void main() {
  test('max hex scale defaults to 256 and round-trips', () {
    expect(AppSettings.defaults.maxHexScale, 256);

    final settings = AppSettings.defaults.copyWith(
      maxHexScale: 32,
      historyDays: 30,
      scanCacheMode: scanCacheModeAdmin1,
      scanCacheRadiusMiles: 100,
    );
    expect(settings.maxHexScale, 32);
    expect(settings.toJson()['maxHexScale'], 32);

    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.maxHexScale, 32);
    expect(restored.historyDays, 30);
    expect(restored.scanCacheMode, scanCacheModeAdmin1);
    expect(restored.scanCacheRadiusMiles, 100);
    expect(restored.travelDownloadEnabled, isFalse);

    final kept = settings.copyWith(historyDays: 9);
    expect(kept.maxHexScale, 32);
    expect(kept.historyDays, 9);
    expect(kept.scanCacheMode, scanCacheModeAdmin1);
  });

  test('invalid stored max hex scale snaps to an allowed step', () {
    AppSettings load(Object? value) {
      return AppSettings.fromJson(<String, dynamic>{'maxHexScale': value});
    }

    expect(AppSettings.fromJson(<String, dynamic>{}).maxHexScale, 256);
    expect(load(null).maxHexScale, 256);
    expect(load(1).maxHexScale, 1);
    expect(load(8).maxHexScale, 8);
    expect(load(256).maxHexScale, 256);
    expect(load(3).maxHexScale, 4);
    expect(load(7).maxHexScale, 8);
    expect(load(0).maxHexScale, 1);
    expect(load(-4).maxHexScale, 1);
    expect(load(999).maxHexScale, 256);
    expect(load(8.6).maxHexScale, 8);
    expect(load('16').maxHexScale, 16);
    expect(load(' 12 ').maxHexScale, 16);
    expect(load('nope').maxHexScale, 256);
    expect(load(true).maxHexScale, 256);
    expect(AppSettings.defaults.copyWith(maxHexScale: 999).maxHexScale, 256);
    expect(AppSettings.defaults.copyWith(maxHexScale: 6).maxHexScale, 8);
  });
}
