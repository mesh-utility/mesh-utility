import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/services/worker_api.dart';

void main() {
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
  });
}
