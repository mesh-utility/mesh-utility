import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/services/worker_api.dart';

void main() {
  group('parseHttpDateHeader', () {
    test('parses an RFC 1123 Date header', () {
      expect(
        parseHttpDateHeader('Mon, 09 Nov 2026 05:52:01 GMT'),
        DateTime.utc(2026, 11, 9, 5, 52, 1),
      );
      expect(
        parseHttpDateHeader('  mon, 09 nov 2026 05:52:01 gmt  '),
        DateTime.utc(2026, 11, 9, 5, 52, 1),
      );
    });

    test('keeps the ISO-8601 fallback', () {
      expect(
        parseHttpDateHeader('2026-11-09T05:52:01.000Z'),
        DateTime.utc(2026, 11, 9, 5, 52, 1),
      );
      expect(
        parseHttpDateHeader('2026-11-09T07:52:01+02:00'),
        DateTime.utc(2026, 11, 9, 5, 52, 1),
      );
    });

    test('returns null for an empty or junk header', () {
      expect(parseHttpDateHeader(''), isNull);
      expect(parseHttpDateHeader('not a date'), isNull);
      expect(parseHttpDateHeader('Mon, 31 Feb 2026 05:52:01 GMT'), isNull);
    });
  });

  group('WorkerApi server date anchor', () {
    test('fetchServerUtcNow stores an RFC 1123 Date header', () async {
      final api = WorkerApi(
        'https://worker.example',
        httpGet: (uri) async {
          expect(uri.path, '/health');
          return http.Response(
            '{"ok":true}',
            200,
            headers: const {
              'content-type': 'application/json',
              'date': 'Mon, 09 Nov 2026 05:52:01 GMT',
            },
          );
        },
      );

      expect(
        await api.fetchServerUtcNow(),
        DateTime.utc(2026, 11, 9, 5, 52, 1),
      );
      expect(api.lastServerDateUtc, DateTime.utc(2026, 11, 9, 5, 52, 1));
    });

    test('a missing Date header leaves the anchor unset', () async {
      final api = WorkerApi(
        'https://worker.example',
        httpGet: (uri) async {
          return http.Response(
            '{"ok":true}',
            200,
            headers: const {'content-type': 'application/json'},
          );
        },
      );

      expect(await api.fetchServerUtcNow(), isNull);
      expect(api.lastServerDateUtc, isNull);
    });
  });

  group('WorkerApi cleanupDeadzoneRows', () {
    test('returns 0 and skips request when hex list is empty', () async {
      var postCalled = false;
      final api = WorkerApi(
        'https://worker.example',
        httpPost: (_, {headers, body}) async {
          postCalled = true;
          return http.Response('{}', 200);
        },
      );

      final deleted = await api.cleanupDeadzoneRows(['', '   ']);
      expect(deleted, equals(0));
      expect(postCalled, isFalse);
    });

    test('deduplicates hexes and returns deleted count from worker', () async {
      Uri? postedUri;
      Map<String, dynamic>? postedBody;

      final api = WorkerApi(
        'https://worker.example',
        httpPost: (uri, {headers, body}) async {
          postedUri = uri;
          postedBody = jsonDecode((body as String?) ?? '{}');
          return http.Response(
            '{"deleted": 398}',
            200,
            headers: const {'content-type': 'application/json'},
          );
        },
      );

      final deleted = await api.cleanupDeadzoneRows([
        ' 40.891200:-77.478997 ',
        '40.891200:-77.478997',
        '40.890150:-77.479725',
      ]);

      expect(deleted, equals(398));
      expect(postedUri?.path, equals('/maintenance/deadzones/cleanup'));
      expect(postedBody, isNotNull);
      expect(
        postedBody!['hexes'],
        equals(['40.891200:-77.478997', '40.890150:-77.479725']),
      );
    });
  });

  group('WorkerApi fetchRawScans', () {
    test(
      'keeps history scans and dead-like scans within deadzone window',
      () async {
        final calls = <Uri>[];

        Future<http.Response> onGet(Uri uri) async {
          calls.add(uri);
          if (uri.path == '/history') {
            return http.Response(
              jsonEncode(['2026-03-27', '2026-03-26', '2026-03-25']),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          if (uri.path == '/history/2026-03-27.ndjson') {
            return http.Response(
              '{"nodeId":"718D349F","rssi":-64,"latitude":40.89,"longitude":-77.47}\n',
              200,
              headers: const {'content-type': 'text/plain'},
            );
          }
          if (uri.path == '/history/2026-03-26.ndjson') {
            return http.Response(
              '{"nodeId":"","rssi":null,"latitude":40.88,"longitude":-77.46}\n',
              200,
              headers: const {'content-type': 'text/plain'},
            );
          }
          if (uri.path == '/history/2026-03-25.ndjson') {
            return http.Response(
              '{"nodeId":"","rssi":null,"latitude":40.87,"longitude":-77.45}\n',
              200,
              headers: const {'content-type': 'text/plain'},
            );
          }
          return http.Response('not found', 404);
        }

        final api = WorkerApi('https://worker.example', httpGet: onGet);

        final scans = await api.fetchRawScans(historyDays: 1, deadzoneDays: 2);

        expect(scans.length, equals(2));
        expect(scans[0].nodeId, equals('718D349F'));
        expect(scans[0].rssi, equals(-64));
        expect(scans[1].nodeId, equals(''));
        expect(scans[1].rssi, isNull);

        final dayCalls = calls
            .where((u) => u.path.endsWith('.ndjson'))
            .toList();
        expect(
          dayCalls.map((u) => u.path).toList(),
          equals(['/history/2026-03-27.ndjson', '/history/2026-03-26.ndjson']),
        );
        expect(
          dayCalls.every(
            (u) =>
                u.queryParameters['pageSize'] == '2000' &&
                u.queryParameters['deadzoneDays'] == '2',
          ),
          isTrue,
        );
      },
    );

    test('passes radius scope to history requests when provided', () async {
      final calls = <Uri>[];

      Future<http.Response> onGet(Uri uri) async {
        calls.add(uri);
        if (uri.path == '/history') {
          return http.Response(
            jsonEncode(['2026-03-27']),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (uri.path == '/history/2026-03-27.ndjson') {
          return http.Response(
            '{"nodeId":"718D349F","rssi":-64,"latitude":40.89,"longitude":-77.47}\n',
            200,
            headers: const {'content-type': 'text/plain'},
          );
        }
        return http.Response('not found', 404);
      }

      final api = WorkerApi('https://worker.example', httpGet: onGet);

      await api.fetchRawScans(
        historyDays: 1,
        deadzoneDays: 1,
        centerLat: 36.1699,
        centerLng: -115.1398,
        radiusMiles: 50,
      );

      final dayCall = calls.singleWhere((u) => u.path.endsWith('.ndjson'));
      expect(dayCall.queryParameters['lat'], equals('36.169900'));
      expect(dayCall.queryParameters['lng'], equals('-115.139800'));
      expect(dayCall.queryParameters['radiusMiles'], equals('50'));
      expect(dayCall.queryParameters.containsKey('minLat'), isFalse);
    });

    test('sends bbox and radius when the area is wider than 250 miles', () async {
      final calls = <Uri>[];

      Future<http.Response> onGet(Uri uri) async {
        calls.add(uri);
        if (uri.path == '/history') {
          return http.Response(
            jsonEncode(['2026-03-27']),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (uri.path == '/history/2026-03-27.ndjson') {
          return http.Response(
            '{"nodeId":"718D349F","rssi":-64,"latitude":40.89,"longitude":-77.47}\n',
            200,
            headers: const {'content-type': 'text/plain'},
          );
        }
        return http.Response('not found', 404);
      }

      final api = WorkerApi('https://worker.example', httpGet: onGet);
      await api.fetchRawScans(
        historyDays: 1,
        deadzoneDays: 1,
        centerLat: 37,
        centerLng: -119,
        radiusMiles: 400,
        minLatitude: 32.5,
        maxLatitude: 42,
        minLongitude: -124.2,
        maxLongitude: -114,
      );

      final dayCall = calls.singleWhere((u) => u.path.endsWith('.ndjson'));
      expect(dayCall.queryParameters['lat'], equals('37.000000'));
      expect(dayCall.queryParameters['lng'], equals('-119.000000'));
      expect(dayCall.queryParameters['radiusMiles'], equals('400'));
      expect(dayCall.queryParameters['minLat'], equals('32.500000'));
      expect(dayCall.queryParameters['maxLat'], equals('42.000000'));
      expect(dayCall.queryParameters['minLng'], equals('-124.200000'));
      expect(dayCall.queryParameters['maxLng'], equals('-114.000000'));
    });

    test('global fetch omits geo params', () async {
      final calls = <Uri>[];

      Future<http.Response> onGet(Uri uri) async {
        calls.add(uri);
        if (uri.path == '/history') {
          return http.Response(
            jsonEncode(['2026-03-27']),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (uri.path == '/history/2026-03-27.ndjson') {
          return http.Response('', 200, headers: const {'content-type': 'text/plain'});
        }
        return http.Response('not found', 404);
      }

      final api = WorkerApi('https://worker.example', httpGet: onGet);
      await api.fetchRawScans(historyDays: 1, deadzoneDays: 1);

      final dayCall = calls.singleWhere((u) => u.path.endsWith('.ndjson'));
      expect(dayCall.queryParameters.containsKey('lat'), isFalse);
      expect(dayCall.queryParameters.containsKey('lng'), isFalse);
      expect(dayCall.queryParameters.containsKey('radiusMiles'), isFalse);
      expect(dayCall.queryParameters.containsKey('minLat'), isFalse);
      expect(dayCall.queryParameters.containsKey('maxLng'), isFalse);
    });
  });

  group('WorkerApi fetchCoverageZones', () {
    test('sends bbox with the radius fallback', () async {
      final calls = <Uri>[];
      final api = WorkerApi(
        'https://worker.example',
        httpGet: (uri) async {
          calls.add(uri);
          return http.Response(
            '[]',
            200,
            headers: const {'content-type': 'application/json'},
          );
        },
      );

      await api.fetchCoverageZones(
        historyDays: 7,
        deadzoneDays: 3,
        centerLat: 37,
        centerLng: -119,
        radiusMiles: 400,
        minLatitude: 32.5,
        maxLatitude: 42,
        minLongitude: -124.2,
        maxLongitude: -114,
      );

      final uri = calls.single;
      expect(uri.path, '/coverage');
      expect(uri.queryParameters['days'], '7');
      expect(uri.queryParameters['deadzoneDays'], '3');
      expect(uri.queryParameters['lat'], '37.000000');
      expect(uri.queryParameters['lng'], '-119.000000');
      expect(uri.queryParameters['radiusMiles'], '400');
      expect(uri.queryParameters['minLat'], '32.500000');
      expect(uri.queryParameters['maxLat'], '42.000000');
      expect(uri.queryParameters['minLng'], '-124.200000');
      expect(uri.queryParameters['maxLng'], '-114.000000');
    });
  });

  group('WorkerApi fetchCoverageOverview', () {
    const headers = {'content-type': 'application/json'};
    const body = {
      'generatedDay': '2026-11-09',
      'scale': 256,
      'cells': [
        {
          'id': '152:-209',
          's': 4,
          'r': 0,
          'n': 1,
          'radioId': 'SECRET',
          'lat': 40.7,
          'timestamp': 1,
        },
      ],
    };

    test('parses a 200 body and drops private fields', () async {
      final api = WorkerApi(
        'https://worker.example',
        httpGet: (uri) async {
          expect(uri.path, '/coverage/overview');
          expect(uri.queryParameters, isEmpty);
          return http.Response(jsonEncode(body), 200, headers: headers);
        },
      );

      final overview = await api.fetchCoverageOverview();
      expect(overview, isNotNull);
      expect(overview!.generatedDay, '2026-11-09');
      expect(overview.scale, 256);
      expect(overview.cells, hasLength(1));
      expect(overview.cells.single.id, '152:-209');
      expect(overview.cells.single.strength, 4);
      expect(overview.cells.single.recency, 0);
      expect(overview.cells.single.toJson().keys, ['id', 's', 'r', 'n']);
    });

    test('a 404 on the primary tries the fallback', () async {
      final hosts = <String>[];
      final api = WorkerApi(
        'https://primary.example',
        fallbackBaseUrl: 'https://fallback.example',
        httpGet: (uri) async {
          hosts.add(uri.host);
          if (uri.host == 'primary.example') {
            return http.Response('missing', 404);
          }
          return http.Response(jsonEncode(body), 200, headers: headers);
        },
      );

      final overview = await api.fetchCoverageOverview();
      expect(hosts, ['primary.example', 'fallback.example']);
      expect(overview?.cells.single.id, '152:-209');
    });

    test('404 on every base returns null', () async {
      final api = WorkerApi(
        'https://primary.example',
        fallbackBaseUrl: 'https://fallback.example',
        httpGet: (uri) async => http.Response('nope', 404),
      );

      expect(await api.fetchCoverageOverview(), isNull);
    });

    test('a 500 on the primary still uses a later 200', () async {
      final api = WorkerApi(
        'https://primary.example',
        fallbackBaseUrl: 'https://fallback.example',
        httpGet: (uri) async {
          if (uri.host == 'primary.example') {
            return http.Response('busy', 500, headers: headers);
          }
          return http.Response(jsonEncode(body), 200, headers: headers);
        },
      );

      expect((await api.fetchCoverageOverview())?.cells.single.strength, 4);
    });

    test('a non-JSON 200 is skipped', () async {
      final api = WorkerApi(
        'https://primary.example',
        fallbackBaseUrl: 'https://fallback.example',
        httpGet: (uri) async {
          if (uri.host == 'primary.example') {
            return http.Response(
              '<html></html>',
              200,
              headers: const {'content-type': 'text/html'},
            );
          }
          return http.Response(jsonEncode(body), 200, headers: headers);
        },
      );

      expect((await api.fetchCoverageOverview())?.generatedDay, '2026-11-09');
    });

    test('a network error returns null instead of throwing', () async {
      final api = WorkerApi(
        'https://worker.example',
        httpGet: (uri) async => throw Exception('offline'),
      );

      expect(await api.fetchCoverageOverview(), isNull);
    });
  });
}
