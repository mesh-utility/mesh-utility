import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/services/tile_cache_stats.dart';
import 'package:mesh_utility/src/services/tile_cache_stats_stub.dart'
    if (dart.library.io) 'package:mesh_utility/src/services/tile_cache_stats_io.dart'
    as tile_cache_stats;

class TileCacheService {
  TileCacheService._();

  static BuiltInMapCachingProvider? _provider;

  static BuiltInMapCachingProvider _providerInstance() {
    return _provider ??= BuiltInMapCachingProvider.getOrCreateInstance(
      maxCacheSize: 1_500_000_000,
      overrideFreshAge: const Duration(days: 30),
    );
  }

  static TileProvider createTileProvider({required bool enabled}) {
    return NetworkTileProvider(
      cachingProvider: enabled
          ? _providerInstance()
          : const DisabledMapCachingProvider(),
    );
  }

  static Future<void> clearCache() async {
    final provider = _provider;
    if (provider == null) return;
    await provider.destroy(deleteCache: true);
    _provider = null;
  }

  static Future<TileCacheStats> getCacheStats() async {
    return tile_cache_stats.readTileCacheStats();
  }

  static Future<int> prefetchAround({
    required double centerLat,
    required double centerLng,
    required List<String> urlTemplates,
    int radiusMiles = 5,
    int minZoom = 11,
    int maxZoom = 15,
    int maxTiles = 900,
  }) async {
    final provider = _providerInstance();
    final client = http.Client();
    var downloaded = 0;
    try {
      final latDelta = (radiusMiles * 1609.344) / 111320.0;
      final lngScale = math.cos(centerLat * (math.pi / 180.0)).abs();
      final safeLngScale = lngScale < 0.0001 ? 0.0001 : lngScale;
      final lngDelta = latDelta / safeLngScale;
      final minLat = centerLat - latDelta;
      final maxLat = centerLat + latDelta;
      final minLng = centerLng - lngDelta;
      final maxLng = centerLng + lngDelta;

      for (final template in urlTemplates) {
        for (var zoom = minZoom; zoom <= maxZoom; zoom++) {
          final xMin = _lngToTileX(minLng, zoom);
          final xMax = _lngToTileX(maxLng, zoom);
          final yMin = _latToTileY(maxLat, zoom);
          final yMax = _latToTileY(minLat, zoom);

          for (var x = xMin; x <= xMax; x++) {
            for (var y = yMin; y <= yMax; y++) {
              if (downloaded >= maxTiles) return downloaded;
              final url = template
                  .replaceAll('{z}', '$zoom')
                  .replaceAll('{x}', '$x')
                  .replaceAll('{y}', '$y');
              try {
                final response = await client
                    .get(Uri.parse(url))
                    .timeout(const Duration(seconds: 8));
                if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
                  continue;
                }
                await provider.putTile(
                  url: url,
                  metadata: CachedMapTileMetadata(
                    staleAt: DateTime.now().toUtc().add(
                      const Duration(days: 30),
                    ),
                    etag: null,
                    lastModified: null,
                  ),
                  bytes: response.bodyBytes,
                );
                downloaded += 1;
              } catch (_) {
                // Best-effort prefetch.
              }
            }
          }
        }
      }
      return downloaded;
    } finally {
      client.close();
    }
  }

  static int _lngToTileX(double lon, int zoom) {
    final n = math.pow(2.0, zoom).toDouble();
    final x = ((lon + 180.0) / 360.0 * n).floor();
    if (x < 0) return 0;
    final max = n.toInt() - 1;
    if (x > max) return max;
    return x;
  }

  static int _latToTileY(double lat, int zoom) {
    final clipped = lat.clamp(-85.05112878, 85.05112878);
    final rad = clipped * math.pi / 180.0;
    final n = math.pow(2.0, zoom).toDouble();
    final y = ((1.0 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) /
            2.0 *
            n)
        .floor();
    if (y < 0) return 0;
    final max = n.toInt() - 1;
    if (y > max) return max;
    return y;
  }
}
