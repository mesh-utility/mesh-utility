import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<String> exportCsvFile({
  required String fileName,
  required String csvContent,
}) async {
  final bytes = utf8.encode(csvContent);
  final jsArray = bytes.toJS;
  final blob = web.Blob(
    [jsArray].toJS,
    web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return 'browser download: $fileName';
}
