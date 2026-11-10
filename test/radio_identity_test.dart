import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/radio_id_utils.dart';

void main() {
  group('resolveConnectedRadioIdentity', () {
    const bleName = 'X Vehicle 1';
    const contacts = <String, String>{
      'AABBCCDD11223344': 'EF Vehicle',
    };

    test('BLE name "X Vehicle 1" does not adopt contact "EF Vehicle"', () {
      final resolved = resolveConnectedRadioIdentity(
        bleDeviceName: bleName,
        contacts: contacts,
      );
      expect(resolved.meshIdPrefix, isNull);
      expect(resolved.displayName, 'X Vehicle 1');
      expect(resolved.displayName, isNot(contains('EF Vehicle')));
    });

    test('self-info name is not replaced by a contact name', () {
      const selfPrefix = '99F00BA1';
      const selfKey = '99F00BA1CAFEBABE';
      final resolved = resolveConnectedRadioIdentity(
        selfInfoMeshIdPrefix: selfPrefix,
        selfInfoPublicKeyHex: selfKey,
        selfInfoDisplayName: "KD3CGK's Vehicle 1",
        bleDeviceName: bleName,
        contacts: {
          selfKey: 'EF Vehicle',
          ...contacts,
        },
      );
      expect(resolved.meshIdPrefix, selfPrefix);
      expect(resolved.displayName, "KD3CGK's Vehicle 1");
      expect(resolved.displayName, isNot('EF Vehicle'));
    });

    test('exact contact key is recognized but still does not supply the name', () {
      const selfPrefix = 'AABBCCDD';
      final name = exactContactNameForKey(
        contacts,
        selfPrefix,
        publicKeyHex: 'AABBCCDD11223344',
      );
      expect(name, 'EF Vehicle');
      final resolved = resolveConnectedRadioIdentity(
        selfInfoMeshIdPrefix: selfPrefix,
        selfInfoPublicKeyHex: 'AABBCCDD11223344',
        selfInfoDisplayName: 'X Vehicle 1',
        bleDeviceName: bleName,
        contacts: contacts,
      );
      expect(resolved.displayName, 'X Vehicle 1');
    });
  });

  group('extractSelfInfoDisplayName', () {
    test('preserves apostrophes and other punctuation', () {
      expect(
        extractSelfInfoDisplayName("MeshCore\$KD3CGK's Vehicle 1"),
        "KD3CGK's Vehicle 1",
      );
      expect(
        extractSelfInfoDisplayName(r'$Millheim (1W)'),
        'Millheim (1W)',
      );
      expect(extractSelfInfoDisplayName("O'Brien Repeater"), "O'Brien Repeater");
    });

    test('strips only control characters', () {
      expect(
        extractSelfInfoDisplayName('Good\u0001Name'),
        'GoodName',
      );
    });
  });

  group('runWithRetries', () {
    test('retries self-info once after a timeout and then succeeds', () async {
      var attempts = 0;
      final result = await runWithRetries(() async {
        attempts += 1;
        if (attempts == 1) {
          throw Exception('timeout');
        }
        return 'ok';
      }, retries: 1);
      expect(result, 'ok');
      expect(attempts, 2);
    });

    test('gives up after the retry budget and leaves identity unknown', () async {
      var attempts = 0;
      await expectLater(
        runWithRetries(() async {
          attempts += 1;
          throw Exception('timeout');
        }, retries: selfInfoTimeoutRetries),
        throwsA(isA<Exception>()),
      );
      expect(attempts, selfInfoTimeoutRetries + 1);

      final resolved = resolveConnectedRadioIdentity(
        bleDeviceName: 'X Vehicle 1',
        contacts: const {'AABBCCDD11223344': 'EF Vehicle'},
      );
      expect(resolved.meshIdPrefix, isNull);
      expect(resolved.displayName, 'X Vehicle 1');
    });
  });

  group('name matching', () {
    test('two known contacts sharing an 8-char prefix leave the short id unnamed', () {
      const shortId = '1052A930';
      const first = '1052A93011111111';
      const second = '1052A93022222222';
      final contacts = <String, String>{first: 'First Repeater', second: 'Second Repeater'};
      expect(resolvedNameForNodeId(contacts, shortId), isNull);
      expect(resolvedNameForNodeId(contacts, first), 'First Repeater');
      expect(resolvedNameForNodeId(contacts, second), 'Second Repeater');
      expect(
        nameKeyAppliesTo(first, shortId, allKnownKeys: contacts.keys),
        isFalse,
      );
      expect(nameKeyAppliesTo(first, first, allKnownKeys: contacts.keys), isTrue);
      expect(nameKeyAppliesTo(first, second, allKnownKeys: contacts.keys), isFalse);
    });

    test('an 8-char scan id may use a name when only one full key is known', () {
      const shortId = '1052A930';
      const longId = '1052A930AABBCCDD';
      final contacts = <String, String>{longId: 'Only Repeater'};
      expect(resolvedNameForNodeId(contacts, shortId), 'Only Repeater');
      expect(resolvedNameForNodeId(contacts, longId), 'Only Repeater');
    });
  });
}
