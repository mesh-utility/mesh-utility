class AppConfig {
  static const String _defaultWorkerUrl = 'https://mesh-utility.org/api';
  static const String _defaultWorkerFallbackUrl =
      'https://mesh-utility-worker.aaffiliate796.workers.dev';
  static const String deployedWorkerUrl = String.fromEnvironment(
    'WORKER_URL',
    defaultValue: _defaultWorkerUrl,
  );
  static const String fallbackWorkerUrl = String.fromEnvironment(
    'WORKER_FALLBACK_URL',
    defaultValue: _defaultWorkerFallbackUrl,
  );
}
