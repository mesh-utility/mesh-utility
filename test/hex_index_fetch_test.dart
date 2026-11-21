import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/app_state.dart';
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

HexDetail _detail(int row) {
  return HexDetail(row: row, col: 1, scanCount: 1, lastTs: 1, bestRssi: -80);
}

void main() {
  group('refreshVisibleHexDetail', () {
    test('a request during a fetch runs afterwards with the latest '
        'viewport', () async {
      final state = _state();
      final seen = <String>[];
      final gates = <Completer<List<HexDetail>>>[];
      state.debugHexIndexFetch =
          ({
            required bool world,
            required int days,
            required bool includeNodes,
            ({double south, double north, double west, double east})? bounds,
          }) {
            seen.add(
              '${bounds?.south},${bounds?.north},${bounds?.west},${bounds?.east}',
            );
            final gate = Completer<List<HexDetail>>();
            gates.add(gate);
            return gate.future;
          };

      final first = state.refreshVisibleHexDetail(
        south: 1,
        north: 2,
        west: 3,
        east: 4,
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, <String>['1.0,2.0,3.0,4.0']);

      unawaited(
        state.refreshVisibleHexDetail(south: 10, north: 11, west: 12, east: 13),
      );
      unawaited(
        state.refreshVisibleHexDetail(south: 20, north: 21, west: 22, east: 23),
      );
      expect(seen, hasLength(1));

      gates.single.complete(<HexDetail>[_detail(1)]);
      await Future<void>.delayed(Duration.zero);
      expect(seen, <String>['1.0,2.0,3.0,4.0', '20.0,21.0,22.0,23.0']);

      gates.last.complete(<HexDetail>[_detail(2)]);
      await first;
      await state.tileZonesSettled;
    });

    test('a queued force is kept when the latest call is not forced', () async {
      final state = _state();
      var calls = 0;
      final gates = <Completer<List<HexDetail>>>[];
      state.debugHexIndexFetch =
          ({
            required bool world,
            required int days,
            required bool includeNodes,
            ({double south, double north, double west, double east})? bounds,
          }) {
            calls += 1;
            final gate = Completer<List<HexDetail>>();
            gates.add(gate);
            return gate.future;
          };

      final first = state.refreshVisibleHexDetail(
        south: 1,
        north: 2,
        west: 3,
        east: 4,
      );
      await Future<void>.delayed(Duration.zero);
      unawaited(
        state.refreshVisibleHexDetail(
          south: 1,
          north: 2,
          west: 3,
          east: 4,
          force: true,
        ),
      );
      unawaited(
        state.refreshVisibleHexDetail(south: 1, north: 2, west: 3, east: 4),
      );
      expect(calls, 1);

      gates.single.complete(<HexDetail>[_detail(1)]);
      await Future<void>.delayed(Duration.zero);
      // Same viewport would hit the cache unless the queued force cleared it.
      expect(calls, 2);

      gates.last.complete(<HexDetail>[_detail(2)]);
      await first;
      await state.tileZonesSettled;
    });

    test('an identical cached index skips the rebuild', () async {
      final state = _state();
      final list = <HexDetail>[_detail(4)];
      var calls = 0;
      state.debugHexIndexFetch =
          ({
            required bool world,
            required int days,
            required bool includeNodes,
            ({double south, double north, double west, double east})? bounds,
          }) {
            calls += 1;
            return Future<List<HexDetail>>.value(list);
          };

      await state.refreshVisibleHexDetail(south: 1, north: 2, west: 3, east: 4);
      await state.tileZonesSettled;
      final zones = state.tileCoverageZones;
      expect(zones, isNotEmpty);

      await state.refreshVisibleHexDetail(south: 1, north: 2, west: 3, east: 4);
      expect(calls, 1);
      expect(identical(state.tileCoverageZones, zones), isTrue);
    });
  });

  group('hex index in flight', () {
    test('two concurrent loads with the same key share one fetch', () async {
      final state = _state();
      var calls = 0;
      final gates = <Completer<List<HexDetail>>>[];
      state.debugHexIndexFetch =
          ({
            required bool world,
            required int days,
            required bool includeNodes,
            ({double south, double north, double west, double east})? bounds,
          }) {
            calls += 1;
            final gate = Completer<List<HexDetail>>();
            gates.add(gate);
            return gate.future;
          };

      const viewport = (south: 1.0, north: 2.0, west: 3.0, east: 4.0);
      final first = state.debugLoadHexIndex(
        days: 7,
        includeNodes: false,
        viewport: viewport,
      );
      final second = state.debugLoadHexIndex(
        days: 7,
        includeNodes: false,
        viewport: viewport,
      );
      final otherKey = state.debugLoadHexIndex(
        days: 7,
        includeNodes: true,
        viewport: viewport,
      );
      expect(calls, 2);

      final list = <HexDetail>[_detail(1)];
      gates[0].complete(list);
      gates[1].complete(list);
      final shared = await Future.wait(<Future<List<HexDetail>?>>[
        first,
        second,
      ]);
      await otherKey;
      expect(calls, 2);
      expect(identical(shared[0], shared[1]), isTrue);
    });

    test('force drops the in-flight entry and starts a fresh fetch', () async {
      final state = _state();
      var calls = 0;
      final gates = <Completer<List<HexDetail>>>[];
      state.debugHexIndexFetch =
          ({
            required bool world,
            required int days,
            required bool includeNodes,
            ({double south, double north, double west, double east})? bounds,
          }) {
            calls += 1;
            final gate = Completer<List<HexDetail>>();
            gates.add(gate);
            return gate.future;
          };

      const viewport = (south: 1.0, north: 2.0, west: 3.0, east: 4.0);
      final first = state.debugLoadHexIndex(
        days: 7,
        includeNodes: false,
        viewport: viewport,
      );
      final shared = state.debugLoadHexIndex(
        days: 7,
        includeNodes: false,
        viewport: viewport,
      );
      expect(calls, 1);

      final forced = state.refreshVisibleHexDetail(
        south: viewport.south,
        north: viewport.north,
        west: viewport.west,
        east: viewport.east,
        force: true,
      );
      expect(calls, 2);

      gates[0].complete(<HexDetail>[_detail(1)]);
      gates[1].complete(<HexDetail>[_detail(2)]);
      await Future.wait<Object?>(<Future<Object?>>[first, shared, forced]);
      await state.tileZonesSettled;
      expect(calls, 2);
    });
  });
}
