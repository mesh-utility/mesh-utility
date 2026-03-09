import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';

class WorkerApi {
  WorkerApi(this.baseUrl);

  final String baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$normalized$path').replace(queryParameters: query);
  }

  String _decodeUtf8(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Future<List<String>> fetchHistoryDays() async {
    final response = await http.get(_uri('/history'));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch history days');
    }
    final decoded = jsonDecode(_decodeUtf8(response));
    if (decoded is! List) return [];
    return decoded.map((e) => e.toString()).toList();
  }

  Future<List<RawScan>> fetchRawScans({
    int historyDays = 7,
    int deadzoneDays = 7,
    String? connectedRadioId,
  }) async {
    final days = await fetchHistoryDays();
    final historyLimit = historyDays > 0 ? historyDays : days.length;
    final deadzoneLimit = deadzoneDays > 0 ? deadzoneDays : days.length;
    final fetchCount = historyLimit > deadzoneLimit
        ? historyLimit
        : deadzoneLimit;
    final selectedDays = days.take(fetchCount).toList(growable: false);
    final viewerRadioId = _normalizeRadioId8(connectedRadioId);

    final results = <RawScan>[];
    for (var i = 0; i < selectedDays.length; i++) {
      final day = selectedDays[i];
      final keepHistory = i < historyLimit;
      final keepDeadzones = i < deadzoneLimit;
      try {
        final query = <String, String>{
          if (deadzoneDays >= 0) 'deadzoneDays': '$deadzoneDays',
        };
        if (viewerRadioId != null) {
          query['viewerRadioId'] = viewerRadioId;
        }
        final response = await http.get(_uri('/history/$day.ndjson', query));
        if (response.statusCode != 200) continue;

        final lines = const LineSplitter().convert(_decodeUtf8(response));
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            final scan = RawScan.fromJson(decoded);
            if (keepHistory || (keepDeadzones && _isDeadLikeScan(scan))) {
              results.add(scan);
            }
          } else if (decoded is Map) {
            final scan = RawScan.fromJson(decoded.cast<String, dynamic>());
            if (keepHistory || (keepDeadzones && _isDeadLikeScan(scan))) {
              results.add(scan);
            }
          }
        }
      } catch (_) {
        continue;
      }
    }

    return results;
  }

  Future<List<CoverageZone>> fetchCoverageZones({
    required int historyDays,
    required int deadzoneDays,
    String? connectedRadioId,
  }) async {
    final viewerRadioId = _normalizeRadioId8(connectedRadioId);
    final query = <String, String>{
      'days': historyDays.toString(),
      'deadzoneDays': deadzoneDays.toString(),
    };
    if (viewerRadioId != null) {
      query['viewerRadioId'] = viewerRadioId;
    }
    final response = await http.get(_uri('/coverage', query));

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch coverage zones');
    }

    final decoded = jsonDecode(_decodeUtf8(response));
    if (decoded is! List) {
      return [];
    }

    return decoded
        .map(
          (e) => e is Map<String, dynamic>
              ? CoverageZone.fromJson(e)
              : CoverageZone.fromJson((e as Map).cast<String, dynamic>()),
        )
        .toList();
  }

  String? _normalizeRadioId8(String? value) {
    if (value == null) return null;
    final cleaned = value.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    if (cleaned.isEmpty) return null;
    return cleaned.length >= 8 ? cleaned.substring(0, 8) : cleaned;
  }

  bool _isDeadLikeScan(RawScan scan) {
    final nodeId = (scan.nodeId ?? '').trim();
    return nodeId.isEmpty || scan.rssi == null;
  }

  Future<int> uploadScans(List<Map<String, dynamic>> scans) async {
    if (scans.isEmpty) return 0;
    final response = await http.post(
      _uri('/scans'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(scans),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Failed to upload scans (${response.statusCode}): ${_decodeUtf8(response)}',
      );
    }
    return scans.length;
  }
}
