String? _meshDatabasePath;

String? currentMeshDatabasePath() => _meshDatabasePath;

void rememberMeshDatabasePath(String path) {
  _meshDatabasePath = path;
}
