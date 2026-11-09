import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/transport/protocol.dart';
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
  const repeaterPrefix = '1052A930AABBCCDD';
  const repeaterShort = '1052A930';
  const roomPrefix = 'AABBCCDD11223344';
  const roomShort = 'AABBCCDD';
  const chatPrefix = 'FEEDFACE01020304';
  const chatShort = 'FEEDFACE';
  const observerId = '718D349F';

  AppState buildState() {
    return AppState(
      settingsStore: SettingsStore(),
      localStore: LocalStore(),
      transport: _FakeTransport(),
    );
  }

  RawScan scanFor({required String nodeId, String? senderName}) {
    return RawScan(
      observerId: observerId,
      nodeId: nodeId,
      latitude: 40.0,
      longitude: -77.0,
      rssi: -70,
      timestamp: DateTime.utc(2026, 1, 1),
      senderName: senderName,
      radioId: observerId,
    );
  }

  test('repeater contact name is preferred over advertised name', () {
    final state = buildState();
    state.debugSeedSessionContacts(
      <String, String>{repeaterPrefix: 'TestRep'},
      types: <String, int>{repeaterPrefix: advTypeRepeater},
    );

    expect(
      state.debugResolveScanSenderName(
        nodeId: repeaterShort,
        advertisedName: 'OtherAdv',
      ),
      'TestRep',
    );
    expect(
      state.debugResolveScanSenderName(
        nodeId: repeaterPrefix,
        advertisedName: repeaterShort,
      ),
      'TestRep',
    );
  });

  test('room contact name is preferred over advertised name', () {
    final state = buildState();
    state.debugSeedSessionContacts(
      <String, String>{roomPrefix: 'TestRoom'},
      types: <String, int>{roomPrefix: advTypeRoom},
    );

    expect(
      state.debugResolveScanSenderName(
        nodeId: roomShort,
        advertisedName: 'OtherAdv',
      ),
      'TestRoom',
    );
  });

  test('chat contact name is not written onto scans', () {
    final state = buildState();
    state.debugSeedSessionContacts(
      <String, String>{chatPrefix: 'TestChat'},
      types: <String, int>{chatPrefix: advTypeChat},
    );

    expect(
      state.debugResolveScanSenderName(
        nodeId: chatShort,
        advertisedName: 'OtherAdv',
      ),
      'OtherAdv',
    );
    expect(
      state.debugResolveScanSenderName(
        nodeId: chatShort,
        advertisedName: chatShort,
      ),
      chatShort,
    );
    expect(state.displayNameForNode(chatShort), 'TestChat');
  });

  test('backfill copies repeater and room names and skips chat names', () {
    final state = buildState();
    state.debugSeedSessionContacts(
      <String, String>{
        repeaterPrefix: 'TestRep',
        roomPrefix: 'TestRoom',
        chatPrefix: 'TestChat',
      },
      types: <String, int>{
        repeaterPrefix: advTypeRepeater,
        roomPrefix: advTypeRoom,
        chatPrefix: advTypeChat,
      },
    );
    state.rawScans = <RawScan>[
      scanFor(nodeId: repeaterShort, senderName: repeaterShort),
      scanFor(nodeId: roomShort, senderName: roomShort),
      scanFor(nodeId: chatShort, senderName: chatShort),
    ];

    final updated = state.debugBackfillScanNamesFromContacts(<String, String>{
      repeaterPrefix: 'TestRep',
      roomPrefix: 'TestRoom',
      chatPrefix: 'TestChat',
    });

    expect(updated, greaterThanOrEqualTo(2));
    expect(state.rawScans[0].senderName, 'TestRep');
    expect(state.rawScans[1].senderName, 'TestRoom');
    expect(state.rawScans[2].senderName, chatShort);
  });

  test('backfill strips a leaked chat contact name from senderName', () {
    final state = buildState();
    state.debugSeedSessionContacts(
      <String, String>{chatPrefix: 'TestChat'},
      types: <String, int>{chatPrefix: advTypeChat},
    );
    state.rawScans = <RawScan>[
      scanFor(nodeId: chatShort, senderName: 'TestChat'),
    ];

    final updated = state.debugBackfillScanNamesFromContacts(<String, String>{
      chatPrefix: 'TestChat',
    });

    expect(updated, greaterThanOrEqualTo(1));
    expect(state.rawScans.single.senderName, chatShort);
  });

  test('upload payload includes repeater and room contact names', () {
    final state = buildState();
    state.debugSeedSessionContacts(
      <String, String>{repeaterPrefix: 'TestRep', roomPrefix: 'TestRoom'},
      types: <String, int>{
        repeaterPrefix: advTypeRepeater,
        roomPrefix: advTypeRoom,
      },
    );

    final repeaterPayload = state.debugToWorkerScanPayload(
      scanFor(nodeId: repeaterShort, senderName: 'TestRep'),
    );
    final roomPayload = state.debugToWorkerScanPayload(
      scanFor(nodeId: roomShort, senderName: 'TestRoom'),
    );

    expect(repeaterPayload, isNotNull);
    expect((repeaterPayload!['nodes'] as List).single['name'], 'TestRep');
    expect(roomPayload, isNotNull);
    expect((roomPayload!['nodes'] as List).single['name'], 'TestRoom');
  });

  test('upload payload omits a companion contact name', () {
    final state = buildState();
    state.debugSeedSessionContacts(
      <String, String>{chatPrefix: 'TestChat'},
      types: <String, int>{chatPrefix: advTypeChat},
    );

    final payload = state.debugToWorkerScanPayload(
      scanFor(nodeId: chatShort, senderName: 'TestChat'),
    );

    expect(payload, isNotNull);
    final node = (payload!['nodes'] as List).single as Map<String, dynamic>;
    expect(node.containsKey('name'), isFalse);
    expect(node['nodeId'], chatShort);
  });

  test(
    'upload payload keeps an advertised name that is not a chat contact',
    () {
      final state = buildState();
      state.debugSeedSessionContacts(
        <String, String>{chatPrefix: 'TestChat'},
        types: <String, int>{chatPrefix: advTypeChat},
      );

      final payload = state.debugToWorkerScanPayload(
        scanFor(nodeId: chatShort, senderName: 'OtherAdv'),
      );

      expect(payload, isNotNull);
      expect((payload!['nodes'] as List).single['name'], 'OtherAdv');
    },
  );

  test('backfill does not attach a name from a weak prefix', () {
    final state = buildState();
    const cellNode = '463D3236';
    const otherLong = '46ABCDEF01234567';
    state.debugSeedSessionContacts(
      <String, String>{'46': 'WrongName', otherLong: 'OtherCell'},
      types: <String, int>{'46': advTypeRepeater, otherLong: advTypeRepeater},
    );
    state.rawScans = <RawScan>[
      scanFor(nodeId: cellNode, senderName: cellNode),
    ];

    final updated = state.debugBackfillScanNamesFromContacts(<String, String>{
      '46': 'WrongName',
      otherLong: 'OtherCell',
    });

    expect(updated, 0);
    expect(state.rawScans.single.senderName, cellNode);
  });

  test('backfill does not attach an ambiguous colliding contact name', () {
    final state = buildState();
    state.debugSeedSessionContacts(
      <String, String>{
        '1052A93011111111': 'First',
        '1052A93022222222': 'Second',
      },
      types: <String, int>{
        '1052A93011111111': advTypeRepeater,
        '1052A93022222222': advTypeRepeater,
      },
    );
    state.rawScans = <RawScan>[
      scanFor(nodeId: repeaterShort, senderName: repeaterShort),
    ];

    final updated = state.debugBackfillScanNamesFromContacts(<String, String>{
      '1052A93011111111': 'First',
      '1052A93022222222': 'Second',
    });

    expect(updated, 0);
    expect(state.rawScans.single.senderName, repeaterShort);
  });

  test('large backfill updates a repeater and strips a chat name', () {
    final state = buildState();
    final contacts = <String, String>{
      for (var i = 0; i < 80; i++) _contactKey(i): 'Contact$i',
      repeaterPrefix: 'TestRep',
      chatPrefix: 'TestChat',
    };
    final types = <String, int>{
      for (final key in contacts.keys) key: advTypeRepeater,
      chatPrefix: advTypeChat,
    };
    state.debugSeedSessionContacts(contacts, types: types);
    state.rawScans = <RawScan>[
      scanFor(nodeId: repeaterShort, senderName: repeaterShort),
      scanFor(nodeId: chatShort, senderName: 'TestChat'),
      for (var i = 0; i < 6000; i++)
        scanFor(
          nodeId: 'A${i.toRadixString(16).padLeft(7, '0')}',
          senderName: 'A${i.toRadixString(16).padLeft(7, '0')}',
        ),
    ];

    final watch = Stopwatch()..start();
    final updated = state.debugBackfillScanNamesFromContacts(contacts);
    expect(watch.elapsedMilliseconds, lessThan(2000));
    expect(updated, 2);
    expect(state.rawScans[0].senderName, 'TestRep');
    expect(state.rawScans[1].senderName, chatShort);
    expect(state.rawScans[2].senderName, 'A0000000');
  });
}

String _contactKey(int index) {
  final head = 'B${index.toRadixString(16).padLeft(7, '0')}';
  final tail = index.toRadixString(16).padLeft(8, 'C');
  return '$head$tail';
}
