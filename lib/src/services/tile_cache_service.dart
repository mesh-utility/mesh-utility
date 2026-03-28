import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/services/tile_cache_stats.dart';
import 'package:mesh_utility/src/services/tile_cache_stats_stub.dart'
    if (dart.library.io) 'package:mesh_utility/src/services/tile_cache_stats_io.dart'
    as tile_cache_stats;

class TileCacheService {
  TileCacheService._();

  static BuiltInMapCachingProvider? _provider;
  static final _sessionProvider = _SessionMapCachingProvider();

  static BuiltInMapCachingProvider _providerInstance() {
    return _provider ??= BuiltInMapCachingProvider.getOrCreateInstance(
      maxCacheSize: 1_500_000_000,
      overrideFreshAge: const Duration(days: 30),
    );
  }

  static TileProvider createTileProvider({required bool enabled}) {
    final persistentProvider = enabled
        ? _providerInstance()
        : const DisabledMapCachingProvider();
    final cacheProvider = _CompositeMapCachingProvider(
      primary: _sessionProvider,
      secondary: persistentProvider,
    );
    return NetworkTileProvider(cachingProvider: cacheProvider);
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

      // Collect all tile URLs up to the limit first.
      final tileUrls = <String>[];
      outer:
      for (final template in urlTemplates) {
        for (var zoom = minZoom; zoom <= maxZoom; zoom++) {
          final xMin = _lngToTileX(minLng, zoom);
          final xMax = _lngToTileX(maxLng, zoom);
          final yMin = _latToTileY(maxLat, zoom);
          final yMax = _latToTileY(minLat, zoom);

          for (var x = xMin; x <= xMax; x++) {
            for (var y = yMin; y <= yMax; y++) {
              if (tileUrls.length >= maxTiles) break outer;
              tileUrls.add(
                template
                    .replaceAll('{z}', '$zoom')
                    .replaceAll('{x}', '$x')
                    .replaceAll('{y}', '$y'),
              );
            }
          }
        }
      }

      // Download and cache tiles with bounded concurrency.
      const concurrency = 8;
      for (var i = 0; i < tileUrls.length; i += concurrency) {
        final end = (i + concurrency).clamp(0, tileUrls.length);
        final batch = tileUrls.sublist(i, end);
        final results = await Future.wait(
          batch.map((url) async {
            try {
              final response = await client
                  .get(Uri.parse(url))
                  .timeout(const Duration(seconds: 8));
              if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
                return false;
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
              return true;
            } catch (_) {
              return false;
            }
          }),
        );
        downloaded += results.where((r) => r).length;
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
    final y =
        ((1.0 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) /
                2.0 *
                n)
            .floor();
    if (y < 0) return 0;
    final max = n.toInt() - 1;
    if (y > max) return max;
    return y;
  }
}

class _CompositeMapCachingProvider implements MapCachingProvider {
  const _CompositeMapCachingProvider({
    required this.primary,
    required this.secondary,
  });

  final MapCachingProvider primary;
  final MapCachingProvider secondary;

  @override
  bool get isSupported => primary.isSupported || secondary.isSupported;

  @override
  Future<CachedMapTile?> getTile(String url) async {
    if (primary.isSupported) {
      final tile = await primary.getTile(url);
      if (tile != null) return tile;
    }
    if (secondary.isSupported) {
      final tile = await secondary.getTile(url);
      if (tile != null) {
        if (primary.isSupported) {
          await primary.putTile(
            url: url,
            metadata: tile.metadata,
            bytes: tile.bytes,
          );
        }
        return tile;
      }
    }
    return null;
  }

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    if (primary.isSupported) {
      await primary.putTile(url: url, metadata: metadata, bytes: bytes);
    }
    if (secondary.isSupported) {
      await secondary.putTile(url: url, metadata: metadata, bytes: bytes);
    }
  }
}

class _SessionMapCachingProvider implements MapCachingProvider {
  static const int _maxEntries = 220;
  static const int _maxBytes = 24 * 1024 * 1024;
  static const Duration _maxTileAge = Duration(minutes: 12);

  final LinkedHashMap<
    String,
    ({Uint8List bytes, CachedMapTileMetadata metadata})
  >
  _cache =
      LinkedHashMap<
        String,
        ({Uint8List bytes, CachedMapTileMetadata metadata})
      >();
  int _bytesInUse = 0;

  @override
  bool get isSupported => true;

  @override
  Future<CachedMapTile?> getTile(String url) async {
    final existing = _cache.remove(url);
    if (existing == null) return null;
    if (existing.metadata.isStale) {
      _bytesInUse -= existing.bytes.lengthInBytes;
      return null;
    }
    _cache[url] = existing;
    return existing;
  }

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    if (bytes == null || bytes.isEmpty) return;

    final nowUtc = DateTime.now().toUtc();
    final maxStaleAt = nowUtc.add(_maxTileAge);
    final cappedMetadata = CachedMapTileMetadata(
      staleAt: metadata.staleAt.isBefore(maxStaleAt)
          ? metadata.staleAt
          : maxStaleAt,
      lastModified: metadata.lastModified,
      etag: metadata.etag,
    );

    final existing = _cache.remove(url);
    if (existing != null) {
      _bytesInUse -= existing.bytes.lengthInBytes;
    }

    final entryBytes = Uint8List.fromList(bytes);
    if (entryBytes.lengthInBytes > _maxBytes) return;

    _cache[url] = (bytes: entryBytes, metadata: cappedMetadata);
    _bytesInUse += entryBytes.lengthInBytes;
    _trim();
  }

  void _trim() {
    while (_cache.length > _maxEntries || _bytesInUse > _maxBytes) {
      if (_cache.isEmpty) break;
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey);
      if (removed != null) {
        _bytesInUse -= removed.bytes.lengthInBytes;
      }
    }
  }
}
