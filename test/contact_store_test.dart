import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/models/local_contact.dart';
import 'package:mesh_utility/src/services/contact_store.dart';

void main() {
  group('filterLocalContacts', () {
    final book = [
      LocalContact(
        publicKeyPrefix: 'AABBCCDD11223344',
        name: 'Rep1',
        type: 2,
        lastHeard: DateTime.utc(2026, 1, 1),
      ),
      LocalContact(
        publicKeyPrefix: 'FFEEDDCC00112233',
        name: 'Chat1',
        type: 1,
        lastHeard: DateTime.utc(2026, 1, 2),
      ),
    ];

    test('matches name case-insensitively', () {
      expect(filterLocalContacts(book, 'rep').single.name, 'Rep1');
    });

    test('matches public key prefix', () {
      expect(filterLocalContacts(book, 'ffee').single.name, 'Chat1');
    });
  });

  group('mergeLocalContact', () {
    test('keeps newer lastHeard and non-empty name', () {
      final a = LocalContact(
        publicKeyPrefix: 'AA',
        name: 'Rep1',
        type: 2,
        lastHeard: DateTime.utc(2026, 1, 1),
      );
      final b = LocalContact(
        publicKeyPrefix: 'AA',
        name: 'Rep1b',
        type: 2,
        lastHeard: DateTime.utc(2026, 1, 3),
        path: 'path1',
        source: 'advert',
      );
      final m = mergeLocalContact(a, b);
      expect(m.name, 'Rep1b');
      expect(m.lastHeard, DateTime.utc(2026, 1, 3));
      expect(m.path, 'path1');
    });
  });

  group('ContactStore merge', () {
    test('merge grows book without duplicates', () async {
      final store = ContactStore();
      const radio = 'RADIODEADBEEF01';
      final first = await store.mergeContacts(radio, [
        LocalContact(
          publicKeyPrefix: 'AAAABBBBCCCCDDDD',
          name: 'Rep1',
          type: 2,
          lastHeard: DateTime.utc(2026, 1, 1),
        ),
      ]);
      expect(first.length, 1);
      final second = await store.mergeContacts(radio, [
        LocalContact(
          publicKeyPrefix: 'AAAABBBBCCCCDDDD',
          name: 'Rep1',
          type: 2,
          lastHeard: DateTime.utc(2026, 1, 2),
        ),
        LocalContact(
          publicKeyPrefix: 'EEEEFFFF00001111',
          name: 'Chat1',
          type: 1,
          lastHeard: DateTime.utc(2026, 1, 2),
          source: 'advert',
        ),
      ]);
      expect(second.length, 2);
    });
  });
}
