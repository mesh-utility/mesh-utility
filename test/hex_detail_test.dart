import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/hex_detail.dart';
import 'package:mesh_utility/src/services/scan_aggregator.dart';

void main() {
  const lockHavenLat = 41.137;
  const lockHavenLng = -77.446;

  test('hex ids match the fixed scale-1 grid', () {
    final cell = hexCellAt(lockHavenLat, lockHavenLng);
    final parsed = parseHexDetailId('hex:${cell.row}:${cell.col}');
    expect(parsed, isNotNull);
    expect(parsed!.row, cell.row);
    expect(parsed.col, cell.col);
    expect(parseHexDetailId('tile:${cell.row}:${cell.col}')!.row, cell.row);
  });

  test('list payload parses full Alpha-24 fields and builds zones', () {
    final cell = hexCellAt(lockHavenLat, lockHavenLng);
    final body = jsonDecode(
      jsonEncode({
        'v': 1,
        'days': 7,
        'h': [
          [
            cell.row,
            cell.col,
            4,
            1730000000000,
            12.0,
            -63.0,
            8.0,
            -70.0,
            180.0,
            lockHavenLat,
            lockHavenLng,
            'N1',
            'Millheim 1W',
            [
              {
                'i': 'N1',
                'n': 'Millheim 1W',
                't': 1730000000000,
                's': 12.0,
                'r': -63.0,
                'c': 3,
              },
            ],
          ],
        ],
      }),
    );
    final details = parseHexListPayload(body);
    expect(details, hasLength(1));
    expect(details.first.scanCount, 4);
    expect(details.first.bestSnr, 12);
    expect(details.first.bestRssi, -63);
    expect(details.first.lastNodeName, 'Millheim 1W');
    expect(details.first.nodes, hasLength(1));
    final zones = coverageZonesFromHexDetails(details);
    expect(zones, hasLength(1));
    expect(zones.first.id, 'hex:${cell.row}:${cell.col}');
    expect(zones.first.scanCount, 4);
    expect(zones.first.avgRssi, -63);
    expect(zones.first.isDeadZone, isFalse);
    final center = hexCellCenter(cell.row, cell.col);
    expect(zones.first.centerLat, closeTo(center.lat, 1e-12));
    expect(zones.first.centerLng, closeTo(center.lng, 1e-12));
    // Payload lat/lng may be a last-scan location, not the cell center.
    expect(zones.first.centerLat, isNot(closeTo(lockHavenLat, 1e-9)));
    final scans = rawScansFromHexDetails(details);
    expect(scans, hasLength(1));
    expect(scans.first.nodeId, 'N1');
    expect(scans.first.senderName, 'Millheim 1W');
    expect(scans.first.downloadedFromWorker, isTrue);
  });

  test('single-hex payload parses for popups', () {
    final raw = jsonDecode(
      jsonEncode({
        'v': 1,
        'days': 0,
        'hex': {
          'id': '10:-20',
          'row': 10,
          'col': -20,
          'scanCount': 2,
          'lastTs': 1000,
          'bestSnr': 5,
          'bestRssi': -80,
          'lat': 1.0,
          'lng': 2.0,
          'lastNodeId': 'A',
          'lastNodeName': 'Alpha',
          'nodes': [
            {'i': 'A', 'n': 'Alpha', 't': 1000, 's': 5, 'r': -80, 'c': 2},
          ],
        },
      }),
    );
    final detail = parseHexDetailPayload(raw);
    expect(detail, isNotNull);
    expect(detail!.id, '10:-20');
    expect(detail.scanCount, 2);
    expect(detail.nodes.first.name, 'Alpha');
  });

  test('world path is used for zoomed-out Global, not a 0.8x1.2 cap', () {
    expect(
      shouldFetchHexWorld(
        south: -80,
        north: 80,
        west: -180,
        east: 180,
        cacheAreaIsGlobal: true,
      ),
      isTrue,
    );
    expect(
      shouldFetchHexWorld(
        south: 41.1,
        north: 41.2,
        west: -77.5,
        east: -77.4,
        cacheAreaIsGlobal: false,
      ),
      isFalse,
    );
    final box = radiusToBounds(lat: 41.1, lng: -77.4, radiusMiles: 50);
    expect(box.north - box.south, greaterThan(1.2));
  });

  test('hex cells are never resized or merged', () {
    final a = hexCellAt(41.137, -77.446);
    final b = hexCellAt(41.137 + rowSpacing * 8, -77.446);
    expect(b.row - a.row, 8);
    final zoneA = coverageZonesFromHexDetails([
      HexDetail(row: a.row, col: a.col, scanCount: 1, lastTs: 1),
      HexDetail(row: b.row, col: b.col, scanCount: 1, lastTs: 1),
    ]);
    expect(zoneA, hasLength(2));
    expect(zoneA[0].id, isNot(zoneA[1].id));
  });

  test('zones snap to row/col center, never last-scan lat/lng', () {
    const row = 39186;
    const col = -53300;
    final center = hexCellCenter(row, col);
    final details = <HexDetail>[
      HexDetail(
        row: row,
        col: col,
        scanCount: 2,
        lastTs: 1,
        lat: center.lat + 0.0004,
        lng: center.lng - 0.0005,
      ),
    ];
    final zones = coverageZonesFromHexDetails(details);
    expect(zones, hasLength(1));
    expect(zones.single.centerLat, closeTo(center.lat, 1e-12));
    expect(zones.single.centerLng, closeTo(center.lng, 1e-12));
    expect(hexDetailCenter(details.single).lat, center.lat);
  });

  test('duplicate cells from index plus local hexKey zones draw once', () {
    final cell = hexCellAt(lockHavenLat, lockHavenLng);
    final indexed = coverageZonesFromHexDetails([
      HexDetail(row: cell.row, col: cell.col, scanCount: 9, lastTs: 2),
    ]);
    final local = coverageZonesFromHexDetails([
      HexDetail(row: cell.row, col: cell.col, scanCount: 1, lastTs: 1),
    ]);
    // Simulate a locally derived zone id in the old hexKey form.
    final hexKeyed = local.single;
    final mixed = dedupeCoverageZonesByCell(indexed, [
      CoverageZone(
        id: hexKey(cell.lat, cell.lng),
        centerLat: hexKeyed.centerLat,
        centerLng: hexKeyed.centerLng,
        radiusMeters: hexKeyed.radiusMeters,
        avgRssi: hexKeyed.avgRssi,
        avgSnr: hexKeyed.avgSnr,
        scanCount: hexKeyed.scanCount,
        lastScanned: hexKeyed.lastScanned,
        isDeadZone: hexKeyed.isDeadZone,
        polygon: hexKeyed.polygon,
      ),
    ]);
    expect(mixed, hasLength(1));
    expect(mixed.single.id, 'hex:${cell.row}:${cell.col}');
    expect(mixed.single.scanCount, 9);
  });

  test('raw scans include repeater and observer names', () {
    final cell = hexCellAt(lockHavenLat, lockHavenLng);
    final scans = rawScansFromHexDetails([
      HexDetail(
        row: cell.row,
        col: cell.col,
        scanCount: 3,
        lastTs: 50,
        lastNodeName: 'Millheim 1W',
        nodes: const [
          HexDetailNode(
            id: 'ABCD1234',
            name: 'Millheim 1W',
            role: 'repeater',
            senderName: 'Millheim 1W',
            receiverName: 'Truck Radio',
            lastTs: 50,
            bestSnr: 8,
            bestRssi: -70,
            count: 3,
          ),
          HexDetailNode(
            id: 'FFFF0001',
            name: 'Truck Radio',
            role: 'observer',
            receiverName: 'Truck Radio',
            lastTs: 50,
            count: 3,
          ),
        ],
      ),
    ]);
    expect(scans, hasLength(2));
    final heard = scans.firstWhere((s) => s.nodeId == 'ABCD1234');
    expect(heard.senderName, 'Millheim 1W');
    expect(heard.receiverName, 'Truck Radio');
    expect(heard.radioId, 'FFFF0001');
    expect(heard.observerId, 'FFFF0001');
    final observer = scans.firstWhere(
      (s) =>
          (s.nodeId == null || s.nodeId!.isEmpty) && s.observerId == 'FFFF0001',
    );
    expect(observer.receiverName, 'Truck Radio');
    expect(observer.radioId, 'FFFF0001');
    expect(observer.nodeId, isNull);
  });

  test(
    'groupRawScansByEvent collapses per-node rows and keeps the best SNR',
    () {
      final ts = DateTime.utc(2026, 11, 10, 12, 38);
      RawScan row({
        required String nodeId,
        required double snr,
        String? receiver,
      }) {
        return RawScan(
          nodeId: nodeId,
          latitude: 40.89015,
          longitude: -77.47827,
          rssi: -80,
          snr: snr,
          timestamp: ts,
          senderName: nodeId,
          receiverName: receiver,
          radioId: 'FB38B387',
        );
      }

      final later = RawScan(
        nodeId: 'EEEE5555',
        latitude: 40.89015,
        longitude: -77.47827,
        rssi: -90,
        snr: 2,
        timestamp: ts.add(const Duration(minutes: 1)),
        senderName: 'EEEE5555',
        receiverName: 'KD3CGK TDeck',
        radioId: 'FB38B387',
      );
      final all = groupRawScansByEvent([
        row(nodeId: 'AAAA1111', snr: 4, receiver: 'KD3CGK TDeck'),
        row(nodeId: 'BBBB2222', snr: 12),
        row(nodeId: 'CCCC3333', snr: 7, receiver: 'KD3CGK TDeck'),
        later,
      ]);
      expect(all, hasLength(2));
      expect(all.first.nodeId, 'EEEE5555'); // newest first
      expect(all.last.nodeId, 'BBBB2222');
      expect(all.last.receiverName, 'KD3CGK TDeck');
    },
  );

  test('rawScansForHexCell drops neighbors and matches the cell count', () {
    final cell = hexCellAt(40.89015, -77.47827);
    final center = hexCellCenter(cell.row, cell.col);
    final neighbor = hexCellCenter(cell.row, cell.col + 1);
    final ts = DateTime.utc(2026, 11, 10, 7, 38);
    RawScan at(({double lat, double lng}) pos, String id) {
      return RawScan(
        nodeId: id,
        latitude: pos.lat,
        longitude: pos.lng,
        rssi: -70,
        snr: 6,
        timestamp: ts,
        radioId: 'FB38B387',
      );
    }

    final kept = rawScansForHexCell(
      scans: [
        at(center, 'A'),
        RawScan(
          nodeId: 'B',
          latitude: center.lat,
          longitude: center.lng,
          rssi: -75,
          snr: 9,
          timestamp: ts,
          radioId: 'FB38B387',
        ),
        at(neighbor, 'C'),
      ],
      row: cell.row,
      col: cell.col,
    );
    expect(kept, hasLength(1));
    expect(kept.single.nodeId, 'B');
    expect(
      isScanInHexCell(
        lat: neighbor.lat,
        lng: neighbor.lng,
        row: cell.row,
        col: cell.col,
      ),
      isFalse,
    );
  });

  test(
    'popup and History counts agree with unique scan events, not index lines',
    () {
      // Live Millheim-style shape: many per-node NDJSON lines (the coverage
      // index scanCount) collapse to one event per timestamp|radio|lat|lng,
      // including same-timestamp reingest duplicates of the same node.
      final cell = hexCellAt(40.8912, -77.478997);
      final ts = DateTime.utc(2026, 11, 10, 6, 50);
      RawScan line({
        required String nodeId,
        required DateTime at,
        String radioId = 'AAAA1111',
        double lat = 40.8912,
        double lng = -77.478997,
        double? snr = 4,
      }) {
        return RawScan(
          nodeId: nodeId,
          latitude: lat,
          longitude: lng,
          rssi: -80,
          snr: snr,
          timestamp: at,
          senderName: nodeId,
          receiverName: 'KD3CGK TDeck',
          radioId: radioId,
        );
      }

      const uniqueEvents = 260;
      final lines = <RawScan>[];
      for (var i = 0; i < uniqueEvents; i++) {
        final at = ts.subtract(Duration(minutes: i));
        // ~3 node lines plus a same-node reingest duplicate on every event.
        lines.add(line(nodeId: '463D3236', at: at, snr: 6));
        lines.add(line(nodeId: '463D3236', at: at, snr: 3)); // dup
        lines.add(line(nodeId: 'NODEAAAA', at: at, snr: 2));
        lines.add(line(nodeId: 'NODEBBBB', at: at, snr: 1));
      }
      // One neighbor-cell line must not inflate the cell count.
      lines.add(
        line(nodeId: 'OUTSIDE', at: ts, lat: 40.8912 + 0.02, lng: -77.478997),
      );

      expect(lines.length, greaterThan(uniqueEvents));
      final inCell = rawScansForHexCell(
        scans: lines,
        row: cell.row,
        col: cell.col,
      );
      expect(inCell, hasLength(uniqueEvents));
      // Strongest SNR row kept, so the same-timestamp node is not listed twice.
      expect(inCell.every((s) => s.nodeId == '463D3236'), isTrue);
      final keys = inCell.map(rawScanEventKey).toSet();
      expect(keys, hasLength(uniqueEvents));
      final history = scanResultsForHexHistory(inCell);
      expect(history, hasLength(uniqueEvents));
    },
  );

  test('unnamed hex node does not inherit another node lastNodeName', () {
    final cell = hexCellAt(lockHavenLat, lockHavenLng);
    final scans = rawScansFromHexDetails([
      HexDetail(
        row: cell.row,
        col: cell.col,
        scanCount: 264,
        lastTs: 50,
        lastNodeId: '8B7DE94C',
        lastNodeName: 'CPAMe.sh Millheim',
        nodes: const [
          HexDetailNode(
            id: '8B7DE94C',
            name: 'CPAMe.sh Millheim',
            role: 'repeater',
            lastTs: 50,
            count: 37,
          ),
          HexDetailNode(id: 'E73FA387', role: 'repeater', lastTs: 40, count: 2),
          HexDetailNode(
            id: '718D349F',
            name: 'CCLRN Millheim',
            role: 'repeater',
            lastTs: 30,
            count: 70,
          ),
        ],
      ),
    ]);
    expect(
      scans.firstWhere((s) => s.nodeId == '8B7DE94C').senderName,
      'CPAMe.sh Millheim',
    );
    expect(
      scans.firstWhere((s) => s.nodeId == '718D349F').senderName,
      'CCLRN Millheim',
    );
    final unnamed = scans.firstWhere((s) => s.nodeId == 'E73FA387');
    expect(unnamed.senderName, isNull);
  });

  test(
    'observers are excluded from Nodes, repeaters stay, History still lists observers',
    () {
      final heardCell = hexCellAt(lockHavenLat, lockHavenLng);
      final deadCell = hexCellAt(lockHavenLat + 0.05, lockHavenLng + 0.05);
      final details = [
        HexDetail(
          row: heardCell.row,
          col: heardCell.col,
          scanCount: 3,
          lastTs: 50,
          lastNodeId: 'ABCD1234',
          lastNodeName: 'Millheim 1W',
          lastRssi: -70,
          lastSnr: 8,
          bestRssi: -70,
          bestSnr: 8,
          nodes: const [
            HexDetailNode(
              id: 'ABCD1234',
              name: 'Millheim 1W',
              role: 'repeater',
              senderName: 'Millheim 1W',
              receiverName: 'KD3CGK TDeck',
              lastTs: 50,
              lastRssi: -70,
              lastSnr: 8,
              bestSnr: 8,
              bestRssi: -70,
              count: 3,
            ),
            HexDetailNode(
              id: 'FB38B387',
              name: 'KD3CGK TDeck',
              role: 'observer',
              receiverName: 'KD3CGK TDeck',
              lastTs: 50,
              count: 3,
            ),
          ],
        ),
        HexDetail(
          row: deadCell.row,
          col: deadCell.col,
          scanCount: 2,
          lastTs: 40,
          lastNodeId: 'FB38B387',
          lastNodeName: 'KD3CGK TDeck',
          nodes: const [
            HexDetailNode(
              id: 'FB38B387',
              name: 'KD3CGK TDeck',
              role: 'observer',
              receiverName: 'KD3CGK TDeck',
              lastTs: 40,
              count: 2,
            ),
          ],
        ),
      ];

      final scans = rawScansFromHexDetails(details);
      final nodes = extractNodes(scans);
      expect(nodes, hasLength(1));
      expect(nodes.single.nodeId, 'ABCD1234');
      expect(nodes.single.name, 'Millheim 1W');
      expect(nodes.map((n) => n.nodeId), isNot(contains('FB38B387')));

      // Per-node filter/zoom still has the repeater's last position.
      final heardCenter = hexDetailCenter(details[0]);
      expect(nodes.single.latitude, closeTo(heardCenter.lat, 0.0001));
      expect(nodes.single.longitude, closeTo(heardCenter.lng, 0.0001));

      final heardHistory = scanResultsForHexHistory(
        scans
            .where(
              (s) =>
                  hexCellAt(s.latitude, s.longitude).row == heardCell.row &&
                  hexCellAt(s.latitude, s.longitude).col == heardCell.col,
            )
            .toList(),
      );
      expect(heardHistory.any((r) => r.receiverName == 'KD3CGK TDeck'), isTrue);
      expect(heardHistory.any((r) => r.nodeId == 'ABCD1234'), isTrue);

      final deadHistory = scanResultsForHexHistory(
        scans
            .where(
              (s) =>
                  hexCellAt(s.latitude, s.longitude).row == deadCell.row &&
                  hexCellAt(s.latitude, s.longitude).col == deadCell.col,
            )
            .toList(),
      );
      expect(deadHistory, isNotEmpty);
      expect(deadHistory.every((r) => r.nodeId.isEmpty), isTrue);
      expect(deadHistory.any((r) => r.receiverName == 'KD3CGK TDeck'), isTrue);

      final zones = coverageZonesFromHexDetails(details);
      expect(zones, hasLength(2));
      final heardZone = zones.firstWhere((z) => z.id == details[0].zoneId);
      final deadZone = zones.firstWhere((z) => z.id == details[1].zoneId);
      expect(heardZone.isDeadZone, isFalse);
      expect(heardZone.scanCount, 3);
      expect(deadZone.isDeadZone, isTrue);
      expect(deadZone.scanCount, 2);
    },
  );
}
