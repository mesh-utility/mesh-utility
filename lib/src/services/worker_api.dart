import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';

class WorkerApi {
  WorkerApi(this.baseUrl, {String? fallbackBaseUrl})
    : _baseUrls = _buildBaseUrls(baseUrl, fallbackBaseUrl);

  final String baseUrl;
  final List<String> _baseUrls;
  DateTime? _lastServerDateUtc;
  DateTime? get lastServerDateUtc => _lastServerDateUtc;

  static List<String> _buildBaseUrls(String primary, String? fallback) {
    final values = <String>{};
    void add(String? value) {
      final v = (value ?? '').trim();
      if (v.isEmpty) return;
      values.add(v);
    }

    add(primary);
    add(fallback);
    return values.toList(growable: false);
  }

  Uri _uri(String base, String path, [Map<String, String>? query]) {
    final normalized = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    return Uri.parse('$normalized$path').replace(queryParameters: query);
  }

  String _decodeUtf8(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  void _captureServerDate(http.Response response) {
    final raw = response.headers['date'];
    if (raw == null || raw.trim().isEmpty) return;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return;
    _lastServerDateUtc = parsed.toUtc();
  }

  bool _looksLikeJsonResponse(http.Response response) {
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    return contentType.contains('application/json');
  }

  bool _looksLikeNdjsonOrJson(http.Response response) {
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (contentType.contains('text/html')) return false;
    return contentType.contains('application/json') ||
        contentType.contains('application/x-ndjson') ||
        contentType.contains('text/plain');
  }

  Future<http.Response> _getWithFallback(
    String path, {
    Map<String, String>? query,
    required bool Function(http.Response response) accept,
  }) async {
    Object? lastError;
    http.Response? lastResponse;
    for (final base in _baseUrls) {
      try {
        final response = await http.get(_uri(base, path, query));
        _captureServerDate(response);
        if (accept(response)) return response;
        lastResponse = response;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastResponse != null) return lastResponse;
    throw Exception('Failed request $path: $lastError');
  }

  Future<http.Response> _postWithFallback(
    String path, {
    Map<String, String>? query,
    required Map<String, String> headers,
    required Object body,
    required bool Function(http.Response response) accept,
  }) async {
    Object? lastError;
    http.Response? lastResponse;
    for (final base in _baseUrls) {
      try {
        final response = await http.post(
          _uri(base, path, query),
          headers: headers,
          body: body,
        );
        _captureServerDate(response);
        if (accept(response)) return response;
        lastResponse = response;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastResponse != null) return lastResponse;
    throw Exception('Failed request $path: $lastError');
  }

  Future<List<String>> fetchHistoryDays() async {
    final response = await _getWithFallback(
      '/history',
      accept: (response) =>
          response.statusCode == 200 && _looksLikeJsonResponse(response),
    );
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
        final response = await _getWithFallback(
          '/history/$day.ndjson',
          query: query,
          accept: (response) =>
              response.statusCode == 200 && _looksLikeNdjsonOrJson(response),
        );
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
    final response = await _getWithFallback(
      '/coverage',
      query: query,
      accept: (response) =>
          response.statusCode == 200 && _looksLikeJsonResponse(response),
    );

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
    final response = await _postWithFallback(
      '/scans',
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(scans),
      accept: (response) =>
          response.statusCode >= 200 &&
          response.statusCode < 300 &&
          _looksLikeJsonResponse(response),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Failed to upload scans (${response.statusCode}): ${_decodeUtf8(response)}',
      );
    }
    return scans.length;
  }

  Future<({String challenge, int expiresAt})> requestDeleteChallenge({
    required String radioId,
    required String publicKeyHex,
  }) async {
    final response = await _postWithFallback(
      '/delete/challenge',
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'radioId': radioId, 'publicKey': publicKeyHex}),
      accept: (response) =>
          response.statusCode >= 200 &&
          response.statusCode < 300 &&
          _looksLikeJsonResponse(response),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Failed to request delete challenge (${response.statusCode}): ${_decodeUtf8(response)}',
      );
    }
    final decoded = jsonDecode(_decodeUtf8(response));
    if (decoded is! Map) {
      throw Exception('Invalid delete challenge response');
    }
    final challenge = decoded['challenge']?.toString() ?? '';
    final expiresAtRaw = decoded['expiresAt'];
    final expiresAt = expiresAtRaw is num
        ? expiresAtRaw.toInt()
        : int.tryParse(expiresAtRaw?.toString() ?? '') ?? 0;
    if (challenge.isEmpty || expiresAt <= 0) {
      throw Exception('Delete challenge response missing required fields');
    }
    return (challenge: challenge, expiresAt: expiresAt);
  }

  Future<({int d1Deleted, int pendingRemoved, int csvRowsRemoved})>
  submitDeleteRequest({
    required String radioId,
    required String publicKeyHex,
    required String challenge,
    required String signatureHex,
  }) async {
    final response = await _postWithFallback(
      '/delete/$radioId',
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'publicKey': publicKeyHex,
        'challenge': challenge,
        'signature': signatureHex,
      }),
      accept: (response) =>
          response.statusCode >= 200 &&
          response.statusCode < 300 &&
          _looksLikeJsonResponse(response),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Delete request failed (${response.statusCode}): ${_decodeUtf8(response)}',
      );
    }
    final decoded = jsonDecode(_decodeUtf8(response));
    if (decoded is! Map) {
      throw Exception('Invalid delete response');
    }
    int toInt(dynamic value) {
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return (
      d1Deleted: toInt(decoded['d1Deleted']),
      pendingRemoved: toInt(decoded['pendingRemoved']),
      csvRowsRemoved: toInt(decoded['csvRowsRemoved']),
    );
  }

  Future<DateTime?> fetchServerUtcNow() async {
    final response = await _getWithFallback(
      '/health',
      accept: (response) =>
          response.statusCode >= 200 &&
          response.statusCode < 300 &&
          _looksLikeJsonResponse(response),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    return _lastServerDateUtc;
  }
}
