import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/radio_id_utils.dart';
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

void main() {
  const shortId = '1052A930';
  const longPrefix = '1052A930AABBCCDD';

  AppState buildState() {
    return AppState(
      settingsStore: SettingsStore(),
      localStore: LocalStore(),
      transport: _FakeTransport(),
    );
  }

  test('session contact name wins over advertised name and short id', () {
    final state = buildState();
    state.debugSeedSessionContacts(<String, String>{
      longPrefix.toLowerCase(): 'TestRep',
      shortId: shortId,
    });
    state.nodes = <MeshNode>[
      MeshNode(
        id: shortId,
        nodeId: shortId,
        name: 'OtherAdv',
        hardwareType: null,
        lastSeen: DateTime.utc(2026, 1, 1),
        latitude: null,
        longitude: null,
      ),
    ];

    expect(state.displayNameForNode(shortId), 'TestRep');
    expect(
      state.displayNameForNode(longPrefix, advertisedName: 'OtherAdv'),
      'TestRep',
    );
    expect(state.displayNameForNode(shortId.toLowerCase()), 'TestRep');
  });

  test('advertised name is used when the session has no contact', () {
    final state = buildState();
    state.nodes = <MeshNode>[
      MeshNode(
        id: shortId,
        nodeId: shortId,
        name: shortId,
        hardwareType: null,
        lastSeen: DateTime.utc(2026, 1, 1),
        latitude: null,
        longitude: null,
      ),
    ];

    expect(
      state.displayNameForNode(shortId, advertisedName: 'OtherAdv'),
      'OtherAdv',
    );
    expect(
      state.displayNameForNode(longPrefix, advertisedName: 'OtherAdv'),
      'OtherAdv',
    );
    expect(state.displayNameForNode(shortId), shortId);
  });

  test('resolved name map skips an id stored under the short key', () {
    final resolved = resolvedNameForNodeId(<String, String>{
      shortId: shortId,
      longPrefix: 'TestRep',
    }, shortId);
    expect(resolved, 'TestRep');
    expect(
      resolvedNameForNodeId(<String, String>{shortId: shortId}, shortId),
      isNull,
    );
  });
}
