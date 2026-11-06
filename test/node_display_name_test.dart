import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/pages/nodes_page.dart';
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
  const abeId = 'EABE1234';

  setUpAll(() async {
    Intl.defaultLocale = 'en_US';
    await initializeDateFormatting('en_US');
  });

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

  test('human names are not treated as hex ids', () {
    expect(isPlaceholderNodeName('TestAbe', abeId), isFalse);
    expect(isPlaceholderNodeName('Cafe', 'CAFE1234'), isFalse);
    expect(isPlaceholderNodeName(abeId, abeId), isTrue);
    expect(isPlaceholderNodeName('EABE1234ABCD', abeId), isTrue);
    expect(isPlaceholderNodeName('EABE:1234', abeId), isTrue);
    expect(isPlaceholderNodeName('Unknown', abeId), isTrue);
    expect(isPlaceholderNodeName('Unknown ($abeId)', abeId), isTrue);

    final state = buildState();
    state.debugSeedSessionContacts(<String, String>{abeId: 'TestAbe'});
    expect(state.displayNameForNode(abeId, advertisedName: abeId), 'TestAbe');
    expect(
      state.displayNameForNode('CAFE1234', advertisedName: 'Cafe'),
      'Cafe',
    );
  });

  test('title uses contact name when the advert is the raw id', () {
    final state = buildState();
    state.debugSeedSessionContacts(<String, String>{
      longPrefix.toLowerCase(): 'TestChat',
    });
    state.nodes = <MeshNode>[_node(nodeId: shortId, name: shortId)];

    final labels = _resolvedLabels(
      state,
      ids: <String>[shortId, longPrefix],
      advertisedName: shortId,
    );
    expect(labels.containsValue(shortId), isFalse);
    expect(labels.containsValue(longPrefix), isFalse);
    expect(resolvedNameForNodeId(labels, shortId), 'TestChat');
    expect(
      titleNameForNode(
        nodeId: shortId,
        contactName: resolvedNameForNodeId(labels, shortId),
        advertisedName: shortId,
      ),
      'TestChat',
    );
    expect(
      titleNameForNode(
        nodeId: longPrefix,
        contactName: 'TestChat',
        advertisedName: shortId,
      ),
      'TestChat',
    );
  });

  test('title uses advertised name when no contact exists', () {
    final state = buildState();
    state.nodes = <MeshNode>[_node(nodeId: shortId, name: shortId)];

    final fromNode = titleNameForNode(
      nodeId: shortId,
      contactName: state.displayNameForNode(shortId),
      advertisedName: 'TestBeacon',
    );
    expect(fromNode, 'TestBeacon');

    final labels = _resolvedLabels(
      state,
      ids: <String>[shortId],
      advertisedName: 'TestBeacon',
    );
    expect(resolvedNameForNodeId(labels, shortId), 'TestBeacon');
    expect(labels.containsValue(shortId), isFalse);
    expect(
      titleNameForNode(
        nodeId: shortId,
        contactName: resolvedNameForNodeId(labels, shortId),
        advertisedName: shortId,
      ),
      'TestBeacon',
    );
  });

  test('title falls back to the short id only when no real name exists', () {
    final state = buildState();
    state.nodes = <MeshNode>[_node(nodeId: longPrefix, name: longPrefix)];

    final labels = _resolvedLabels(
      state,
      ids: <String>[longPrefix, shortId],
      advertisedName: longPrefix,
    );
    expect(labels, isEmpty);
    expect(resolvedNameForNodeId(labels, longPrefix), isNull);
    expect(
      titleNameForNode(
        nodeId: longPrefix,
        contactName: resolvedNameForNodeId(labels, longPrefix),
        advertisedName: longPrefix,
      ),
      shortId,
    );
    expect(titleNameForNode(nodeId: longPrefix, advertisedName: null), shortId);
  });

  test('resolved map does not keep id placeholders that hide a real name', () {
    final labels = <String, String>{};
    putResolvedNodeLabel(labels, shortId, shortId);
    putResolvedNodeLabel(labels, longPrefix, longPrefix);
    expect(labels, isEmpty);

    putResolvedNodeLabel(labels, shortId, 'TestBeacon');
    putResolvedNodeLabel(labels, shortId, shortId);
    putResolvedNodeLabel(labels, longPrefix, longPrefix);
    expect(resolvedNameForNodeId(labels, shortId), 'TestBeacon');
    expect(labels.containsValue(shortId), isFalse);
    expect(labels.containsValue(longPrefix), isFalse);
  });

  test('contact match log records flags without a name', () {
    final state = buildState();
    state.debugSeedSessionContacts(<String, String>{longPrefix: 'TestChat'});
    state.nodes = <MeshNode>[
      _node(nodeId: shortId, name: shortId),
      _node(nodeId: abeId, name: 'TestBeacon'),
    ];

    final before = state.debugLogs.length;
    state.debugLogKnownNodeContactMatches();
    final added = state.debugLogs.skip(before).toList();
    expect(added, hasLength(2));

    final messages = added.map((entry) => entry.message).toList();
    expect(
      messages,
      contains('contacts_match node=$shortId matched=yes has_advert_name=no'),
    );
    expect(
      messages,
      contains('contacts_match node=$abeId matched=no has_advert_name=yes'),
    );
    for (final message in messages) {
      expect(message, isNot(contains('TestChat')));
      expect(message, isNot(contains('TestBeacon')));
      expect(
        message,
        matches(
          RegExp(
            r'^contacts_match node=[0-9A-F]{8} matched=(yes|no) has_advert_name=(yes|no)$',
          ),
        ),
      );
    }
  });

  testWidgets('nodes card title is a name and the id stays the subtitle', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _nodesApp(
        nodes: <MeshNode>[_node(nodeId: shortId, name: shortId)],
        scans: <ScanResult>[_scan(nodeId: shortId, senderName: shortId)],
        resolvedNodeNames: <String, String>{shortId: 'TestChat'},
      ),
    );
    await tester.pump();

    final cardTexts = _cardTexts(tester);
    expect(cardTexts.first, 'TestChat');
    expect(cardTexts, contains(shortId));
    expect(cardTexts.where((text) => text == shortId), hasLength(1));
    expect(_inkWellLabel(tester), startsWith('TestChat'));

    await tester.pumpWidget(
      _nodesApp(
        nodes: <MeshNode>[_node(nodeId: shortId, name: shortId)],
        scans: <ScanResult>[_scan(nodeId: shortId, senderName: 'TestBeacon')],
        resolvedNodeNames: const <String, String>{},
      ),
    );
    await tester.pump();
    expect(_cardTexts(tester).first, 'TestBeacon');
    expect(_inkWellLabel(tester), startsWith('TestBeacon'));

    await tester.pumpWidget(
      _nodesApp(
        nodes: <MeshNode>[_node(nodeId: longPrefix, name: longPrefix)],
        scans: <ScanResult>[_scan(nodeId: longPrefix, senderName: longPrefix)],
        resolvedNodeNames: <String, String>{longPrefix: longPrefix},
      ),
    );
    await tester.pump();
    final fallback = _cardTexts(tester);
    expect(fallback.first, shortId);
    expect(fallback, contains(longPrefix));
    final fallbackLabel = _inkWellLabel(tester);
    expect(fallbackLabel.startsWith(shortId), isTrue);
    expect(fallbackLabel.startsWith(longPrefix), isFalse);
    semantics.dispose();
  });
}

MeshNode _node({required String nodeId, required String? name}) {
  return MeshNode(
    id: nodeId,
    nodeId: nodeId,
    name: name,
    hardwareType: null,
    lastSeen: DateTime.utc(2026, 1, 1, 12),
    latitude: null,
    longitude: null,
  );
}

ScanResult _scan({required String nodeId, required String senderName}) {
  return ScanResult(
    id: 'scan-$nodeId',
    observerId: '718D349F',
    nodeId: nodeId,
    rssi: -70,
    snr: 5,
    snrIn: null,
    latitude: 40,
    longitude: -77,
    altitude: null,
    timestamp: DateTime.utc(2026, 1, 1, 12),
    senderName: senderName,
    receiverName: null,
    radioId: '718D349F',
  );
}

Map<String, String> _resolvedLabels(
  AppState state, {
  required List<String> ids,
  required String? advertisedName,
}) {
  final labels = <String, String>{};
  for (final id in ids) {
    putResolvedNodeLabel(
      labels,
      id,
      state.displayNameForNode(id, advertisedName: advertisedName),
    );
  }
  return labels;
}

Widget _nodesApp({
  required List<MeshNode> nodes,
  required List<ScanResult> scans,
  required Map<String, String> resolvedNodeNames,
}) {
  return MaterialApp(
    home: Scaffold(
      body: NodesPage(
        nodes: nodes,
        scanResults: scans,
        resolvedNodeNames: resolvedNodeNames,
        onOpenMapForNode: (_) {},
      ),
    ),
  );
}

final Finder _nodeCard = find.byType(Card);

List<String> _cardTexts(WidgetTester tester) {
  return tester
      .widgetList<Text>(
        find.descendant(of: _nodeCard, matching: find.byType(Text)),
      )
      .map((text) => text.data ?? '')
      .where((text) => text.isNotEmpty)
      .toList();
}

String _inkWellLabel(WidgetTester tester) {
  return tester
      .getSemantics(
        find.descendant(
          of: _nodeCard,
          matching: find.byWidgetPredicate(
            (widget) => widget is InkWell && widget.onTap != null,
          ),
        ),
      )
      .label;
}
