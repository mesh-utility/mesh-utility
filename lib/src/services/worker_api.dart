import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/hex_detail.dart';
import 'package:mesh_utility/src/services/history_pipeline.dart';
import 'package:mesh_utility/src/services/off_ui.dart';

typedef HttpGetFn = Future<http.Response> Function(Uri uri);
typedef HttpPostFn =
    Future<http.Response> Function(
      Uri uri, {
      Map<String, String>? headers,
      Object? body,
    });

/// IMF-fixdate / RFC 1123, for example `Mon, 09 Nov 2026 05:52:01 GMT`.
final RegExp _rfc1123Date = RegExp(
  r'^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s+(\d{2})\s+'
  r'(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+'
  r'(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$',
  caseSensitive: false,
);

const Map<String, int> _rfc1123Months = <String, int>{
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Parses an HTTP `Date` header. RFC 1123 is tried first. ISO-8601 still works.
///
/// Returns null for an empty or unrecognized value. Does not import `dart:io`.
DateTime? parseHttpDateHeader(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final rfc = _rfc1123Date.firstMatch(trimmed);
  if (rfc != null) {
    final day = int.parse(rfc.group(1)!);
    final month = _rfc1123Months[rfc.group(2)!.toLowerCase()];
    final year = int.parse(rfc.group(3)!);
    final hour = int.parse(rfc.group(4)!);
    final minute = int.parse(rfc.group(5)!);
    final second = int.parse(rfc.group(6)!);
    if (month == null || hour > 23 || minute > 59 || second > 59 || day < 1) {
      return null;
    }
    final parsed = DateTime.utc(year, month, day, hour, minute, second);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return parsed;
  }
  return DateTime.tryParse(trimmed)?.toUtc();
}

/// Reads an HTTP header in a case-insensitive way.
///
/// Some HTTP stacks preserve the original `X-Has-More` casing; looking up
/// only the lowercase key would stop `/scans/area` pagination after page 1.
String? responseHeader(http.Response response, String name) {
  final want = name.toLowerCase();
  for (final entry in response.headers.entries) {
    if (entry.key.toLowerCase() == want) return entry.value;
  }
  return null;
}

Map<String, String> _queryWithOptionalArea({
  Map<String, String>? base,
  double? centerLat,
  double? centerLng,
  int? radiusMiles,
  double? minLatitude,
  double? maxLatitude,
  double? minLongitude,
  double? maxLongitude,
}) {
  final query = <String, String>{...?base};
  if (centerLat != null &&
      centerLng != null &&
      radiusMiles != null &&
      radiusMiles > 0) {
    query['lat'] = centerLat.toStringAsFixed(6);
    query['lng'] = centerLng.toStringAsFixed(6);
    query['radiusMiles'] = '$radiusMiles';
  }
  if (minLatitude != null &&
      maxLatitude != null &&
      minLongitude != null &&
      maxLongitude != null &&
      minLatitude.isFinite &&
      maxLatitude.isFinite &&
      minLongitude.isFinite &&
      maxLongitude.isFinite) {
    query['minLat'] = minLatitude.toStringAsFixed(6);
    query['maxLat'] = maxLatitude.toStringAsFixed(6);
    query['minLng'] = minLongitude.toStringAsFixed(6);
    query['maxLng'] = maxLongitude.toStringAsFixed(6);
  }
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
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse(
      '$normalized$normalizedPath',
    ).replace(queryParameters: query);
  }

  Uri? _staticUri(String path, [Map<String, String>? query]) {
    final base = _staticDataBaseUrl;
    if (base == null) return null;
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  String _decodeUtf8(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  /// Browsers hide `Date` unless CORS exposes it. A missing header leaves
  /// the anchor unset. Reading the header must not throw.
  void _captureServerDate(http.Response response) {
    String? raw;
    try {
      raw = response.headers['date'];
    } catch (_) {
      return;
    }
    if (raw == null || raw.trim().isEmpty) return;
    final parsed = parseHttpDateHeader(raw);
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

  /// True when `/health` answers. Travel downloads use this so a dead network
  /// does not start a fetch. Offline Mode is checked by the caller first.
  Future<bool> canReach() async {
    try {
      final response = await _getWithFallback(
        '/health',
        accept: (response) =>
            response.statusCode == 200 && _looksLikeJsonResponse(response),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<HexDetail>> fetchHexWorld({
    int days = 0,
    bool includeNodes = true,
  }) async {
    Object? lastError;
    for (final base in _baseUrls) {
      try {
        final response = await _httpGet(
          _uri(base, '/coverage/hex-world', <String, String>{
            'days': '$days',
            'nodes': includeNodes ? '1' : '0',
          }),
        ).timeout(const Duration(seconds: 45));
        _captureServerDate(response);
        if (response.statusCode == 404) continue;
        if (response.statusCode == 200 && _looksLikeJsonResponse(response)) {
          final decoded = jsonDecode(_decodeUtf8(response));
          return parseHexListPayload(decoded);
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) return const <HexDetail>[];
    return const <HexDetail>[];
  }

  Future<List<HexDetail>> fetchHexViewport({
    required double minLatitude,
    required double maxLatitude,
    required double minLongitude,
    required double maxLongitude,
    int days = 0,
    bool includeNodes = true,
  }) async {
    Object? lastError;
    for (final base in _baseUrls) {
      try {
        final response = await _httpGet(
          _uri(base, '/coverage/hex-viewport', <String, String>{
            'minLat': minLatitude.toStringAsFixed(6),
            'maxLat': maxLatitude.toStringAsFixed(6),
            'minLng': minLongitude.toStringAsFixed(6),
            'maxLng': maxLongitude.toStringAsFixed(6),
            'days': '$days',
            'nodes': includeNodes ? '1' : '0',
          }),
        ).timeout(const Duration(seconds: 30));
        _captureServerDate(response);
        if (response.statusCode == 404) continue;
        if (response.statusCode == 200 && _looksLikeJsonResponse(response)) {
          final decoded = jsonDecode(_decodeUtf8(response));
          return parseHexListPayload(decoded);
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) return const <HexDetail>[];
    return const <HexDetail>[];
  }

  Future<HexDetail?> fetchIndexedHexDetail(String hexId, {int days = 0}) async {
    final parsed = parseHexDetailId(hexId);
    if (parsed == null) return null;
    final id = '${parsed.row}:${parsed.col}';
    Object? lastError;
    for (final base in _baseUrls) {
      try {
        final response = await _httpGet(
          _uri(base, '/coverage/hex/$id', <String, String>{'days': '$days'}),
        ).timeout(const Duration(seconds: 15));
        _captureServerDate(response);
        if (response.statusCode == 404) continue;
        if (response.statusCode == 200 && _looksLikeJsonResponse(response)) {
          final decoded = jsonDecode(_decodeUtf8(response));
          return parseHexDetailPayload(decoded);
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) return null;
    return null;
  }

  /// Indexed area scans across days from `/scans/area` (one request per page).
  /// Never uses the static whole-day files. [maxRows] caps the total.
  Future<List<RawScan>> fetchAreaScans({
    required double minLatitude,
    required double maxLatitude,
    required double minLongitude,
    required double maxLongitude,
    int days = 30,
    int maxRows = 5000,
    bool markDownloaded = false,
  }) async {
    final all = <RawScan>[];
    int? cursorTimestamp;
    int? cursorId;
    // Worker caps pageSize at 1000 scan rows (each may expand to several
    // NDJSON node lines). Follow X-Has-More until every page is in, not a
    // fixed 20-page ceiling.
    const maxPages = 500;
    for (var page = 0; page < maxPages && all.length < maxRows; page++) {
      final query = <String, String>{
        'minLat': minLatitude.toStringAsFixed(6),
        'maxLat': maxLatitude.toStringAsFixed(6),
        'minLng': minLongitude.toStringAsFixed(6),
        'maxLng': maxLongitude.toStringAsFixed(6),
        'days': '$days',
        'pageSize': '$_historyPageSize',
      };
      if (cursorTimestamp != null && cursorId != null) {
        query['cursorTimestamp'] = '$cursorTimestamp';
        query['cursorId'] = '$cursorId';
      }
      final response = await _getWithFallback(
        '/scans/area',
        query: query,
        accept: (response) =>
            response.statusCode == 200 && _looksLikeNdjsonOrJson(response),
      );
      if (response.statusCode != 200) break;
      all.addAll(
        await _parseScansOffUi(
          response.bodyBytes,
          markDownloaded: markDownloaded,
        ),
      );
      final hasMore =
          (responseHeader(response, 'x-has-more') ?? '').trim() == '1';
      if (!hasMore) break;
      cursorTimestamp = int.tryParse(
        (responseHeader(response, 'x-next-cursor-timestamp') ?? '').trim(),
      );
      cursorId = int.tryParse(
        (responseHeader(response, 'x-next-cursor-id') ?? '').trim(),
      );
      if (cursorTimestamp == null || cursorId == null) break;
    }
    return all;
  }

  Future<List<RawScan>> fetchRawScans({
    int historyDays = 7,
    int deadzoneDays = 7,
    String? connectedRadioId,
    double? centerLat,
    double? centerLng,
    int? radiusMiles,
    double? minLatitude,
    double? maxLatitude,
    double? minLongitude,
    double? maxLongitude,
    bool markDownloaded = false,
    void Function(int completedDays, int totalDays)? onDayProgress,
    bool Function()? isCancelled,
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
    final totalDays = selectedDays.length;
    onDayProgress?.call(0, totalDays);
    for (var i = 0; i < selectedDays.length; i++) {
      if (isCancelled?.call() == true) {
        throw const HistoryLoadCancelled();
      }
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
          minLatitude: minLatitude,
          maxLatitude: maxLatitude,
          minLongitude: minLongitude,
          maxLongitude: maxLongitude,
          markDownloaded: markDownloaded,
          isCancelled: isCancelled,
        );
        if (keepHistory) {
          results.addAll(dayScans);
        } else if (keepDeadzones) {
          for (final scan in dayScans) {
            if (_isDeadLikeScan(scan)) results.add(scan);
          }
        }
      } on HistoryLoadCancelled {
        rethrow;
      } catch (_) {
        continue;
      } finally {
        onDayProgress?.call(i + 1, totalDays);
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
    double? minLatitude,
    double? maxLatitude,
    double? minLongitude,
    double? maxLongitude,
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
      minLatitude: minLatitude,
      maxLatitude: maxLatitude,
      minLongitude: minLongitude,
      maxLongitude: maxLongitude,
    );
    if (_staticHistoryReady) {
      try {
        final staticResponse = await _getStatic(
          '/coverage.json',
          query: query,
          accept: (response) =>
              response.statusCode == 200 && _looksLikeJsonResponse(response),
        );
        final zones = await _parseCoverageOffUi(staticResponse.bodyBytes);
        if (zones != null) return zones;
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

    return await _parseCoverageOffUi(response.bodyBytes) ??
        const <CoverageZone>[];
  }

  Future<List<CoverageZone>?> _parseCoverageOffUi(List<int> bytes) {
    return runOffUi(parseCoverageZoneBytes, bytes, force: true);
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
    double? minLatitude,
    double? maxLatitude,
    double? minLongitude,
    double? maxLongitude,
    bool markDownloaded = false,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() == true) {
      throw const HistoryLoadCancelled();
    }
    if (_staticDataBaseUrl != null) {
      try {
        final staticResponse = await _getStatic(
          '/history/$day.ndjson',
          accept: (response) =>
              response.statusCode == 200 && _looksLikeNdjsonOrJson(response),
        );
        return await _parseScansOffUi(
          staticResponse.bodyBytes,
          markDownloaded: markDownloaded,
        );
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
      minLatitude: minLatitude,
      maxLatitude: maxLatitude,
      minLongitude: minLongitude,
      maxLongitude: maxLongitude,
    );
    final all = <RawScan>[];
    int? cursorTimestamp;
    int? cursorId;
    for (var page = 0; page < 200; page++) {
      if (isCancelled?.call() == true) {
        throw const HistoryLoadCancelled();
      }
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
      all.addAll(
        await _parseScansOffUi(
          response.bodyBytes,
          markDownloaded: markDownloaded,
        ),
      );
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

  Future<List<RawScan>> _parseScansOffUi(
    List<int> bytes, {
    required bool markDownloaded,
  }) {
    return runOffUi(parseRawScanBytesWorker, <String, Object?>{
      'bytes': bytes,
      'downloadedFromWorker': markDownloaded,
    }, force: true);
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
