import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/hex_detail.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/transport/transport_core.dart';

class _FakeTransport extends Transport {
  _FakeTransport() : super('fake');

  @override
  bool get isConnected => false;

  @override
  Stream<Uint8List> get inbound => const Stream<Uint8List>.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> send(Uint8List payload) async {}
}

AppState _state() => AppState(
  settingsStore: SettingsStore(),
  localStore: LocalStore(),
  transport: _FakeTransport(),
);

List<HexDetail> _details(double lat, double lng, {int cells = 3}) {
  final start = hexCellAt(lat, lng);
  return <HexDetail>[
    for (var i = 0; i < cells; i++)
      HexDetail(
        row: start.row + i * 2,
        col: start.col,
        scanCount: 1,
        lastTs: 1,
      ),
  ];
}

void main() {
  group('hex index refresh for a new viewport', () {
    test('same cached index list skips the rebuild and the notify', () {
      final state = _state();
      var notifies = 0;
      state.addListener(() => notifies++);
      final index = _details(41.1, -77.4);

      expect(state.applyHexIndexToTiles(index), isTrue);
      expect(notifies, 1);
      final zones = state.tileCoverageZones;
      expect(zones, hasLength(3));

      // Panning/zooming hands back the identical cached list.
      expect(state.applyHexIndexToTiles(index), isFalse);
      expect(state.applyHexIndexToTiles(index), isFalse);
      expect(notifies, 1);
      expect(identical(state.tileCoverageZones, zones), isTrue);
    });

    test('a newly fetched index list still rebuilds and notifies', () {
      final state = _state();
      var notifies = 0;
      state.addListener(() => notifies++);
      final first = _details(41.1, -77.4);
      state.applyHexIndexToTiles(first);
      final before = state.tileCoverageZones;

      // Same content but a new fetch (new list) must not be skipped.
      final refetched = List<HexDetail>.of(first);
      expect(state.applyHexIndexToTiles(refetched), isTrue);
      expect(notifies, 2);
      expect(identical(state.tileCoverageZones, before), isFalse);

      final other = _details(40.0, -75.0, cells: 5);
      expect(state.applyHexIndexToTiles(other), isTrue);
      expect(notifies, 3);
      expect(state.tileCoverageZones, hasLength(5));
    });
  });

  group('merged map zone list memo', () {
    test('returns the same merged list while inputs are unchanged', () {
      final state = _state();
      state.tileCoverageZones = coverageZonesFromHexDetails(
        _details(41.1, -77.4),
      );
      state.coverageZones = coverageZonesFromHexDetails(
        _details(41.1, -77.4, cells: 1),
      );
      final a = state.mapCoverageZones;
      final b = state.mapCoverageZones;
      expect(identical(a, b), isTrue);
      // Local cell overlaps a tile cell: deduped by cell.
      expect(a, hasLength(3));
    });

    test('invalidates when the tile zones change', () {
      final state = _state();
      state.tileCoverageZones = coverageZonesFromHexDetails(
        _details(41.1, -77.4),
      );
      final before = state.mapCoverageZones;
      state.tileCoverageZones = coverageZonesFromHexDetails(
        _details(41.1, -77.4, cells: 4),
      );
      final after = state.mapCoverageZones;
      expect(identical(before, after), isFalse);
      expect(after, hasLength(4));
      expect(identical(after, state.mapCoverageZones), isTrue);
    });

    test('invalidates when the local zones change', () {
      final state = _state();
      state.tileCoverageZones = coverageZonesFromHexDetails(
        _details(41.1, -77.4),
      );
      final before = state.mapCoverageZones;
      expect(before, hasLength(3));
      state.coverageZones = coverageZonesFromHexDetails(
        _details(40.0, -75.0, cells: 2),
      );
      final after = state.mapCoverageZones;
      expect(identical(before, after), isFalse);
      expect(after, hasLength(5));
    });

    test('with no tile zones the local list is returned as is', () {
      final state = _state();
      final local = coverageZonesFromHexDetails(_details(41.1, -77.4));
      state.coverageZones = local;
      expect(identical(state.mapCoverageZones, local), isTrue);
    });
  });
}
