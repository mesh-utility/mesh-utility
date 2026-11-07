import 'package:mesh_utility/src/services/history_pipeline.dart';

Future<LoadedHistory> loadPersistedHistory(
  String databasePath, {
  void Function(int loadedScans)? onLoaded,
}) async {
  throw UnsupportedError('Background history load is not available');
}
