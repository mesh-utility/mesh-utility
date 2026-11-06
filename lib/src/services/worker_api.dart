import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';

typedef HttpGetFn = Future<http.Response> Function(Uri uri);
typedef HttpPostFn =
    Future<http.Response> Function(
      Uri uri, {
      Map<String, String>? headers,
      Object? body,
    });

/// Converts an untyped [Map] to `Map<String, dynamic>` without throwing on
/// non-string keys — unknown key types are stringified.
Map<String, dynamic> _safeMap(Map<dynamic, dynamic> m) {
  return {for (final e in m.entries) e.key.toString(): e.value};
}

Map<String, String> _queryWithOptionalArea({
  Map<String, String>? base,
  double? centerLat,
  double? centerLng,
  int? radiusMiles,
}) {
  final query = <String, String>{...?base};
  if (centerLat == null ||
      centerLng == null ||
      radiusMiles == null ||
      radiusMiles <= 0) {
    return query;
  }
  query['lat'] = centerLat.toStringAsFixed(6);
  query['lng'] = centerLng.toStringAsFixed(6);
  query['radiusMiles'] = '$radiusMiles';
  return query;
}

class WorkerApi {
  WorkerApi(
    this.baseUrl, {
    String? fallbackBaseUrl,
    String? staticDataBaseUrl,
    HttpGetFn? httpGet,
    HttpPostFn? httpPost,
  }) : _baseUrls = _buildBaseUrls(baseUrl, fallbackBaseUrl),
       _staticDataBaseUrl = _normalizeStaticBaseUrl(staticDataBaseUrl),
       _httpGet = httpGet ?? http.get,
       _httpPost = httpPost ?? http.post;

  final String baseUrl;
  final List<String> _baseUrls;
  final String? _staticDataBaseUrl;
  final HttpGetFn _httpGet;
  final HttpPostFn _httpPost;
  static const int _historyPageSize = 2000;
  bool _staticHistoryReady = false;
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

  static String? _normalizeStaticBaseUrl(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) return null;
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  Uri _uri(String base, String path, [Map<String, String>? query]) {
    final normalized = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    return Uri.parse('$normalized$path').replace(queryParameters: query);
  }

  Uri? _staticUri(String path, [Map<String, String>? query]) {
    final base = _staticDataBaseUrl;
    if (base == null) return null;
    return Uri.parse('$base$path').replace(queryParameters: query);
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
        final response = await _httpGet(_uri(base, path, query));
        _captureServerDate(response);
        if (accept(response)) return response;
        lastResponse = response;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastResponse != null) {
      throw Exception(
        'Failed request $path: unacceptable response '
        'status=${lastResponse.statusCode} '
        'contentType=${lastResponse.headers['content-type'] ?? 'unknown'}',
      );
    }
    throw Exception('Failed request $path: $lastError');
  }

  Future<http.Response> _getStatic(
    String path, {
    Map<String, String>? query,
    required bool Function(http.Response response) accept,
  }) async {
    final uri = _staticUri(path, query);
    if (uri == null) {
      throw Exception('Static data URL not configured');
    }
    final response = await _httpGet(uri).timeout(const Duration(seconds: 5));
    _captureServerDate(response);
    if (!accept(response)) {
      throw Exception(
        'Static request $path rejected: '
        'status=${response.statusCode} '
        'contentType=${response.headers['content-type'] ?? 'unknown'}',
      );
    }
    return response;
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
        final response = await _httpPost(
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
    if (lastResponse != null) {
      throw Exception(
        'Failed request $path: unacceptable response '
        'status=${lastResponse.statusCode} '
        'contentType=${lastResponse.headers['content-type'] ?? 'unknown'}',
      );
    }
    throw Exception('Failed request $path: $lastError');
  }

  Future<int> cleanupDeadzoneRows(Iterable<String> hexes) async {
    final normalized = hexes
        .map((hex) => hex.trim())
        .where((hex) => hex.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalized.isEmpty) return 0;
    final response = await _postWithFallback(
      '/maintenance/deadzones/cleanup',
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'hexes': normalized}),
      accept: (response) =>
          response.statusCode == 200 && _looksLikeJsonResponse(response),
    );
    final decoded = jsonDecode(_decodeUtf8(response));
    if (decoded is Map && decoded['deleted'] is num) {
      return (decoded['deleted'] as num).toInt();
    }
    return 0;
  }

  Future<List<String>> fetchHistoryDays() async {
    if (_staticDataBaseUrl != null) {
      try {
        final staticResponse = await _getStatic(
          '/history/index.json',
          accept: (response) =>
              response.statusCode == 200 && _looksLikeJsonResponse(response),
        );
        final decoded = jsonDecode(_decodeUtf8(staticResponse));
        if (decoded is List) {
          _staticHistoryReady = true;
          return decoded.map((e) => e.toString()).toList(growable: false);
        }
        if (decoded is Map && decoded['days'] is List) {
          _staticHistoryReady = true;
          return (decoded['days'] as List)
              .map((e) => e.toString())
              .toList(growable: false);
        }
      } catch (_) {
        _staticHistoryReady = false;
      }
    }
    _staticHistoryReady = false;

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
    double? centerLat,
    double? centerLng,
    int? radiusMiles,
  }) async {
    final days = await fetchHistoryDays();
    final historyLimit = historyDays > 0 ? historyDays : days.length;
    final deadzoneLimit = deadzoneDays > 0 ? deadzoneDays : days.length;
    final fetchCount = historyLimit > deadzoneLimit
        ? historyLimit
        : deadzoneLimit;
    final selectedDays = days.take(fetchCount).toList(growable: false);
    _normalizeRadioId8(connectedRadioId);

    final results = <RawScan>[];
    for (var i = 0; i < selectedDays.length; i++) {
      final day = selectedDays[i];
      final keepHistory = i < historyLimit;
      final keepDeadzones = i < deadzoneLimit;
      try {
        final dayScans = await _fetchRawScansForDay(
          day: day,
          deadzoneDays: deadzoneDays,
          centerLat: centerLat,
          centerLng: centerLng,
          radiusMiles: radiusMiles,
        );
        for (final scan in dayScans) {
          if (keepHistory || (keepDeadzones && _isDeadLikeScan(scan))) {
            results.add(scan);
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
    double? centerLat,
    double? centerLng,
    int? radiusMiles,
  }) async {
    _normalizeRadioId8(connectedRadioId);
    final query = _queryWithOptionalArea(
      base: <String, String>{
        'days': historyDays.toString(),
        'deadzoneDays': deadzoneDays.toString(),
      },
      centerLat: centerLat,
      centerLng: centerLng,
      radiusMiles: radiusMiles,
    );
    if (_staticHistoryReady) {
      try {
        final staticResponse = await _getStatic(
          '/coverage.json',
          query: query,
          accept: (response) =>
              response.statusCode == 200 && _looksLikeJsonResponse(response),
        );
        final decoded = jsonDecode(_decodeUtf8(staticResponse));
        if (decoded is List) {
          return decoded
              .map(
                (e) => e is Map<String, dynamic>
                    ? CoverageZone.fromJson(e)
                    : CoverageZone.fromJson(_safeMap(e as Map)),
              )
              .toList(growable: false);
        }
      } catch (_) {
        // Fall through to dynamic API.
      }
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
              : CoverageZone.fromJson(_safeMap(e as Map)),
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

  Future<List<RawScan>> _fetchRawScansForDay({
    required String day,
    required int deadzoneDays,
    double? centerLat,
    double? centerLng,
    int? radiusMiles,
  }) async {
    if (_staticDataBaseUrl != null) {
      try {
        final staticResponse = await _getStatic(
          '/history/$day.ndjson',
          accept: (response) =>
              response.statusCode == 200 && _looksLikeNdjsonOrJson(response),
        );
        return _parseRawScansNdjson(_decodeUtf8(staticResponse));
      } catch (_) {
        // Fall through to dynamic API for this day.
      }
    }

    final query = _queryWithOptionalArea(
      base: <String, String>{
        if (deadzoneDays >= 0) 'deadzoneDays': '$deadzoneDays',
      },
      centerLat: centerLat,
      centerLng: centerLng,
      radiusMiles: radiusMiles,
    );
    final all = <RawScan>[];
    int? cursorTimestamp;
    int? cursorId;
    for (var page = 0; page < 200; page++) {
      final pagedQuery = <String, String>{
        ...query,
        'pageSize': '$_historyPageSize',
      };
      if (cursorTimestamp != null && cursorId != null) {
        pagedQuery['cursorTimestamp'] = '$cursorTimestamp';
        pagedQuery['cursorId'] = '$cursorId';
      }
      final response = await _getWithFallback(
        '/history/$day.ndjson',
        query: pagedQuery,
        accept: (response) =>
            response.statusCode == 200 && _looksLikeNdjsonOrJson(response),
      );
      if (response.statusCode != 200) break;
      all.addAll(_parseRawScansNdjson(_decodeUtf8(response)));
      final hasMore = (response.headers['x-has-more'] ?? '').trim() == '1';
      if (!hasMore) break;
      cursorTimestamp = int.tryParse(
        (response.headers['x-next-cursor-timestamp'] ?? '').trim(),
      );
      cursorId = int.tryParse(
        (response.headers['x-next-cursor-id'] ?? '').trim(),
      );
      if (cursorTimestamp == null || cursorId == null) break;
    }
    return all;
  }

  List<RawScan> _parseRawScansNdjson(String payload) {
    final parsed = <RawScan>[];
    final trimmed = payload.trim();
    if (trimmed.isEmpty) return parsed;

    // Accept both NDJSON and JSON array payloads for compatibility.
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          for (final row in decoded) {
            if (row is Map<String, dynamic>) {
              parsed.add(RawScan.fromJson(row));
            } else if (row is Map) {
              parsed.add(RawScan.fromJson(_safeMap(row)));
            }
          }
          return parsed;
        }
      } catch (_) {
        return parsed;
      }
    }

    final lines = const LineSplitter().convert(payload);
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          parsed.add(RawScan.fromJson(decoded));
        } else if (decoded is Map) {
          parsed.add(RawScan.fromJson(_safeMap(decoded)));
        }
      } catch (_) {
        // Skip malformed rows instead of failing full sync.
      }
    }
    return parsed;
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
