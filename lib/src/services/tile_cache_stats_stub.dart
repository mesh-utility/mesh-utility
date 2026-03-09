import 'package:mesh_utility/src/services/tile_cache_stats.dart';

Future<TileCacheStats> readTileCacheStats() async {
  return const TileCacheStats(supported: false, tileCount: 0, totalBytes: 0);
}
