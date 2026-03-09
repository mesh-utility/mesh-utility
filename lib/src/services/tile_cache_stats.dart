class TileCacheStats {
  const TileCacheStats({
    required this.supported,
    required this.tileCount,
    required this.totalBytes,
  });

  final bool supported;
  final int tileCount;
  final int totalBytes;
}
