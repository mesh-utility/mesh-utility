import 'package:mesh_utility/src/services/history_csv_exporter_stub.dart'
    if (dart.library.io) 'package:mesh_utility/src/services/history_csv_exporter_io.dart'
    if (dart.library.js_interop) 'package:mesh_utility/src/services/history_csv_exporter_web.dart'
    as impl;

Future<String> exportCsvFile({
  required String fileName,
  required String csvContent,
}) {
  return impl.exportCsvFile(fileName: fileName, csvContent: csvContent);
}
