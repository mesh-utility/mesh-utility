class AppConfig {
  static const String _defaultWorkerUrl =
      'https://mesh-utility-worker.aaffiliate796.workers.dev';
  static const String deployedWorkerUrl = String.fromEnvironment(
    'WORKER_URL',
    defaultValue: _defaultWorkerUrl,
  );
}
