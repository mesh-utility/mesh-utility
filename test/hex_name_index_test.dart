import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/mesh_node.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/hex_name_index.dart';
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
  const longId = '1052A930AABBCCDD';

  AppState buildState() {
    return AppState(
      settingsStore: SettingsStore(),
      localStore: LocalStore(),
      transport: _FakeTransport(),
    );
  }

  test('idsLikelySameDevice requires an 8-char prefix', () {
    expect(idsLikelySameDevice(shortId, longId), isTrue);
    expect(idsLikelySameDevice(longId, shortId), isTrue);
    expect(idsLikelySameDevice(shortId, shortId), isTrue);
    expect(idsLikelySameDevice('46', '463D3236'), isFalse);
    expect(idsLikelySameDevice('463D3236', '46ABCDEF01234567'), isFalse);
    expect(
      idsLikelySameDevice('1052A93011111111', '1052A93022222222'),
      isFalse,
    );
    expect(hexIdsAreOneRadio(<String>[shortId, longId]), isTrue);
    expect(
      hexIdsAreOneRadio(<String>['1052A93011111111', '1052A93022222222']),
      isFalse,
    );
  });

  test('first advertised name keeps walk order inside a prefix group', () {
    final index = FirstAdvertisedNameIndex()
      ..add(shortId, 'EarlierShort')
      ..add(longId, 'ExactLong')
      ..add('1052A93011111111', 'First')
      ..add('1052A93022222222', 'Second');

    expect(index.lookup(longId), 'EarlierShort');
    expect(index.lookup(shortId), 'EarlierShort');
    expect(index.lookup('1052A93022222222'), 'EarlierShort');
    expect(index.lookup('DEADBEEF'), isNull);
  });

  test('placeholder advertised names are skipped until a real name', () {
    final index = FirstAdvertisedNameIndex()
      ..add(shortId, shortId)
      ..add(shortId, 'Unknown ($shortId)')
      ..add(longId, 'Beacon');

    expect(index.lookup(shortId), 'Beacon');
    expect(index.lookup(longId), 'Beacon');
    expect(index.lookup('not-a-device'), isNull);
  });

  test('first of two real names in one prefix group wins', () {
    final index = FirstAdvertisedNameIndex()
      ..add('1052A93011111111', 'First')
      ..add('1052A93022222222', 'Second');

    expect(index.lookup('1052A93022222222'), 'First');
    expect(index.lookup(shortId), 'First');
  });

  test('a short hash does not inherit an advertised name from another radio', () {
    final index = FirstAdvertisedNameIndex()
      ..add(shortId, 'Beacon')
      ..add('46', 'Other');

    expect(index.lookup('46'), 'Other');
    expect(index.lookup('463D3236'), isNull);
    expect(index.lookup(shortId), 'Beacon');
  });

  test('non-hex advertised ids keep the first raw string', () {
    final index = FirstAdvertisedNameIndex()
      ..add('ZZZ-radio', 'First')
      ..add('ZZZ-radio', 'Second')
      ..add('zzz-radio', 'Third');

    expect(index.lookup('ZZZ-radio'), 'First');
    expect(index.lookup('  ZZZ-radio  '), 'First');
    expect(index.lookup('other-radio'), isNull);
  });

  test('advertised index matches a linear walk', () {
    final random = Random(7);
    const lengths = <int>[4, 6, 8, 16];
    final rows = <(String, String?)>[];
    for (var i = 0; i < 240; i++) {
      final id = _hex(random, lengths[i % lengths.length]);
      final roll = random.nextInt(10);
      final String? name;
      if (roll < 3) {
        name = null;
      } else if (roll < 5) {
        name = '   ';
      } else if (roll < 7) {
        name = id;
      } else {
        name = 'Name$i';
      }
      rows.add((id, name));
    }
    rows.add((shortId, shortId));
    rows.add((longId, 'Beacon'));
    rows.add(('ZZZ-radio', 'Plain'));

    final index = FirstAdvertisedNameIndex();
    for (final row in rows) {
      index.add(row.$1, row.$2);
    }

    final queries = <String>[
      for (final row in rows) row.$1,
      for (final row in rows)
        if (normalizeHexId(row.$1).length >= 8)
          normalizeHexId(row.$1).substring(0, 8),
      longId.toLowerCase(),
      'DEADBEEF',
      '',
      'ZZZ-radio',
    ];
    for (final query in queries) {
      expect(
        index.lookup(query),
        _bruteAdvertised(rows, query),
        reason: 'query $query',
      );
    }
  });

  test('longest contact key wins and placeholders use the query id', () {
    final longest = LongestHexNameIndex.fromMap(<String, String>{
      shortId: 'ShortName',
      longId: 'LongName',
    });
    expect(longest.lookup(shortId), 'LongName');
    expect(longest.lookup(longId), 'LongName');

    final tied = LongestHexNameIndex.fromMap(<String, String>{
      '1052A93011111111': 'First',
      '1052A93022222222': 'Second',
    });
    expect(tied.lookup(shortId), isNull);
    expect(tied.lookup('1052A93022222222'), 'Second');
    expect(tied.lookup('1052A93011111111'), 'First');

    final placeholder = LongestHexNameIndex.fromMap(<String, String>{
      longId: shortId,
      shortId: 'Beacon',
    });
    expect(placeholder.lookup(shortId), 'Beacon');
    expect(placeholder.lookup('DEADBEEF'), isNull);

    final placeholderOnly = LongestHexNameIndex.fromMap(<String, String>{
      longId: shortId,
    });
    expect(placeholderOnly.lookup(shortId), isNull);
    expect(placeholderOnly.lookup(longId), isNull);
    expect(placeholderOnly.matchesId(shortId), isTrue);
    expect(placeholderOnly.matchesId('DEADBEEF'), isFalse);

    final books = <Map<String, String>>[
      <String, String>{shortId: 'ShortName', longId: 'LongName'},
      <String, String>{
        '1052A93011111111': 'First',
        '1052A93022222222': 'Second',
      },
      <String, String>{longId: shortId, shortId: 'Beacon'},
      <String, String>{longId: shortId},
      <String, String>{'DEADBEEF': '   ', 'CAFE1234': 'Cafe'},
    ];
    const probes = <String>[shortId, longId, 'DEADBEEF', 'CAFE1234', 'cafe1234'];
    for (final book in books) {
      final index = LongestHexNameIndex.fromMap(book);
      for (final probe in probes) {
        expect(
          index.lookup(probe),
          _bruteContact(book, probe),
          reason: 'probe $probe',
        );
      }
    }
  });

  test('longest contact type follows the longest key', () {
    final types = LongestHexTypeIndex(<String, int>{
      shortId: 1,
      longId: 2,
      'DEADBEEF': 4,
    });

    expect(types.lookup(shortId), 2);
    expect(types.lookup(longId), 2);
    expect(types.lookup('DEADBEEF'), 4);
    expect(types.lookup(''), isNull);
  });

  test('stored names prefer nodes, then scan results, then raw scans', () {
    final state = buildState();
    state.nodes = <MeshNode>[_node(shortId, 'FromNode')];
    state.scanResults = <ScanResult>[_result(shortId, 'FromResult')];
    state.rawScans = <RawScan>[_raw(longId, 'FromRaw')];

    expect(state.displayNameForNode(longId), 'FromNode');

    state.nodes = const <MeshNode>[];
    expect(state.displayNameForNode(longId), 'FromResult');

    state.scanResults = const <ScanResult>[];
    expect(state.displayNameForNode(longId), 'FromRaw');
  });

  test('a placeholder node does not hide a later advertised name', () {
    final state = buildState();
    state.nodes = <MeshNode>[_node(shortId, shortId)];
    state.scanResults = <ScanResult>[_result(longId, 'Beacon')];

    expect(state.displayNameForNode(shortId), 'Beacon');
    expect(state.displayNameForNode('DEADBEEF'), 'DEADBEEF');
  });

  test('large history name lookup stays on the indexed path', () {
    final state = buildState();
    final scans = <RawScan>[
      _raw(shortId, shortId),
      for (var i = 0; i < 6000; i++)
        _raw('A${i.toRadixString(16).padLeft(7, '0')}', null),
      _raw(longId, 'Beacon'),
      _raw('1052A93011223344', 'Second'),
    ];
    state.rawScans = scans;

    final watch = Stopwatch()..start();
    for (var i = 0; i < 4000; i++) {
      final id = i.isEven ? shortId : scans[i].nodeId!;
      final name = state.displayNameForNode(id);
      if (i.isEven) expect(name, 'Beacon');
    }
    expect(watch.elapsedMilliseconds, lessThan(2000));
    expect(state.displayNameForNode(longId), 'Beacon');
    expect(state.displayNameForNode('1052A93011223344'), 'Beacon');

    state.rawScans = <RawScan>[_raw(shortId, 'Replaced')];
    expect(state.displayNameForNode(longId), 'Replaced');
  });
}

String? _bruteAdvertised(List<(String, String?)> rows, String query) {
  final target = normalizeHexId(query);
  if (target.isEmpty && query.trim().isEmpty) return null;

  bool matches(String candidate) {
    if (target.isEmpty) return candidate.trim() == query.trim();
    final hex = normalizeHexId(candidate);
    if (hex.isEmpty) return false;
    if (hex == target || idsLikelySameDevice(hex, target)) return true;
    if (hex.length >= 8 && target.length >= 8) {
      return hex.substring(0, 8) == target.substring(0, 8);
    }
    return false;
  }

  String? usable(String? name, String id) {
    final trimmed = (name ?? '').trim();
    if (trimmed.isEmpty || isPlaceholderNodeName(trimmed, id)) return null;
    return trimmed;
  }

  for (final row in rows) {
    if (!matches(row.$1)) continue;
    final name = usable(row.$2, row.$1);
    if (name != null) return name;
  }
  return null;
}

String? _bruteContact(Map<String, String> contacts, String id) {
  if (id.isEmpty || contacts.isEmpty) return null;
  final upper = normalizeHexId(id);
  if (upper.isEmpty) return null;
  final matched = <(String, String)>[];
  for (final entry in contacts.entries) {
    final prefix = normalizeHexId(entry.key);
    if (prefix.isEmpty) continue;
    if (prefix != upper && !idsLikelySameDevice(prefix, upper)) continue;
    final name = entry.value.trim();
    if (name.isEmpty || isPlaceholderNodeName(name, upper)) continue;
    matched.add((prefix, name));
  }
  if (matched.isEmpty) return null;
  if (!hexIdsAreOneRadio(matched.map((m) => m.$1))) return null;
  String? bestName;
  var bestLength = -1;
  for (final m in matched) {
    if (m.$1.length > bestLength) {
      bestLength = m.$1.length;
      bestName = m.$2;
    }
  }
  return bestName;
}

String _hex(Random random, int length) {
  const alphabet = '0123456789ABCDEF';
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(alphabet[random.nextInt(alphabet.length)]);
  }
  return buffer.toString();
}

MeshNode _node(String nodeId, String name) {
  return MeshNode(
    id: nodeId,
    nodeId: nodeId,
    name: name,
    hardwareType: null,
    lastSeen: DateTime.utc(2026, 1, 1),
    latitude: null,
    longitude: null,
  );
}

ScanResult _result(String nodeId, String senderName) {
  return ScanResult(
    id: nodeId,
    observerId: '718D349F',
    nodeId: nodeId,
    rssi: -70,
    snr: null,
    snrIn: null,
    latitude: 40,
    longitude: -77,
    altitude: null,
    timestamp: DateTime.utc(2026, 1, 1),
    senderName: senderName,
    receiverName: null,
    radioId: '718D349F',
  );
}

RawScan _raw(String nodeId, String? senderName) {
  return RawScan(
    observerId: '718D349F',
    nodeId: nodeId,
    latitude: 40,
    longitude: -77,
    rssi: -70,
    timestamp: DateTime.utc(2026, 1, 1),
    senderName: senderName,
    radioId: '718D349F',
  );
}
