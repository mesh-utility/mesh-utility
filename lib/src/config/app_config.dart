class AppConfig {
  // API is now routed through mesh-utility.org/api to the Worker.
  // workers.dev stays the fallback when the primary host is unreachable.
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
  // Optional static data origin (for phased static read migration).
  // Example: https://mesh-utility.org
  static const String staticDataUrl = String.fromEnvironment(
    'STATIC_DATA_URL',
    defaultValue: '',
  );
}
