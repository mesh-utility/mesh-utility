import 'dart:io';

import 'package:mesh_utility/src/services/tile_cache_stats.dart';
import 'package:path_provider/path_provider.dart';

Future<TileCacheStats> readTileCacheStats() async {
  final baseDir = await getApplicationCacheDirectory();
  final separator = Platform.pathSeparator;
  final cacheDir = Directory('${baseDir.path}${separator}fm_cache');
  if (!await cacheDir.exists()) {
    return const TileCacheStats(supported: true, tileCount: 0, totalBytes: 0);
  }

  var tileCount = 0;
  var totalBytes = 0;
  await for (final entity in cacheDir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final normalized = entity.path.replaceAll('\\', '/');
    if (normalized.endsWith('/sizeMonitor.bin')) continue;
    tileCount += 1;
    totalBytes += await entity.length();
  }

  return TileCacheStats(
    supported: true,
    tileCount: tileCount,
    totalBytes: totalBytes,
  );
}
