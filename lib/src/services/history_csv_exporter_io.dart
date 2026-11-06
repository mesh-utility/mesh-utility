import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<String> exportCsvFile({
  required String fileName,
  required String csvContent,
}) async {
  Directory? targetDirectory;
  try {
    targetDirectory = await getDownloadsDirectory();
  } catch (_) {
    targetDirectory = null;
  }
  targetDirectory ??= await getApplicationDocumentsDirectory();
  final path = '${targetDirectory.path}${Platform.pathSeparator}$fileName';
  final file = File(path);
  await file.writeAsString(csvContent);
  return file.path;
}
