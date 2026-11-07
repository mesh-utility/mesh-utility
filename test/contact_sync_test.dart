import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/pages/contacts_page.dart';
import 'package:mesh_utility/transport/ble_frame_assembler.dart';
import 'package:mesh_utility/transport/contact_sync.dart';
import 'package:mesh_utility/transport/protocol.dart';

Uint8List _le32(int value) {
  final out = Uint8List(4);
  out[0] = value & 0xff;
  out[1] = (value >> 8) & 0xff;
  out[2] = (value >> 16) & 0xff;
  out[3] = (value >> 24) & 0xff;
  return out;
}

Uint8List buildContactsStartFrame(int total) {
  final out = Uint8List(5);
  out[0] = respCodeContactsStart;
  out.setRange(1, 5, _le32(total));
  return out;
}

Uint8List buildEndOfContactsFrame({int lastmod = 0}) {
  final out = Uint8List(5);
  out[0] = respCodeEndOfContacts;
  out.setRange(1, 5, _le32(lastmod));
  return out;
}

/// Synthetic RESP_CONTACT with a unique pubkey prefix and printable name.
Uint8List buildSyntheticContactFrame({
  required int index,
  required String name,
  int type = advTypeRepeater,
  int lastMod = 0,
}) {
  final frame = Uint8List(contactFrameSize);
  frame[0] = respCodeContact;
  // 32-byte pubkey: unique across 0..N by putting the index in big-endian
  // across the first 4 bytes, then a stable filler (never collide at 256).
  frame[contactPubKeyOffset] = (index >> 24) & 0xff;
  frame[contactPubKeyOffset + 1] = (index >> 16) & 0xff;
  frame[contactPubKeyOffset + 2] = (index >> 8) & 0xff;
  frame[contactPubKeyOffset + 3] = index & 0xff;
  for (var i = 4; i < 32; i++) {
    frame[contactPubKeyOffset + i] = (0xA5 ^ i) & 0xff;
  }
  frame[contactTypeOffset] = type;
  final nameBytes = utf8.encode(name);
  final len = nameBytes.length > maxNameSize ? maxNameSize : nameBytes.length;
  frame.setRange(contactNameOffset, contactNameOffset + len, nameBytes);
  frame.setRange(
    contactLastModOffset,
    contactLastModOffset + 4,
    _le32(lastMod),
  );
  return frame;
}

String syntheticContactPrefix(int index) {
  final frame = buildSyntheticContactFrame(index: index, name: 'Rep$index');
  return parseRadioContact(frame)!.publicKeyPrefix;
}

/// Minimal PUSH advert-like frame that is not a contact.
Uint8List buildPushAdvertFrame({int payloadLen = 8}) {
  final out = Uint8List(4 + payloadLen);
  out[0] = pushCodeNewAdvert;
  out[1] = 0;
  out[2] = 0;
  out[3] = payloadLen;
  for (var i = 0; i < payloadLen; i++) {
    out[4 + i] = i & 0xff;
  }
  return out;
}

List<Uint8List> chunkBytes(Uint8List frame, int chunkSize) {
  final chunks = <Uint8List>[];
  for (var i = 0; i < frame.length; i += chunkSize) {
    final end = (i + chunkSize < frame.length) ? i + chunkSize : frame.length;
    chunks.add(frame.sublist(i, end));
  }
  return chunks;
}

void main() {
  group('BleFrameAssembler', () {
    test(
      'reassembles chunked contacts and survives interleaved push frames',
      () {
        final assembler = BleFrameAssembler();
        final frames = <Uint8List>[];
        const total = 750;

        frames.addAll(assembler.push(buildContactsStartFrame(total)));

        for (var i = 0; i < total; i++) {
          final contact = buildSyntheticContactFrame(
            index: i,
            name: 'Rep$i',
            type: i.isEven ? advTypeRepeater : advTypeChat,
          );
          // Split contact across BLE-sized chunks.
          for (final chunk in chunkBytes(contact, 20)) {
            frames.addAll(assembler.push(chunk));
          }
          // Interleave a push every 10 contacts mid-stream.
          if (i % 10 == 9) {
            frames.addAll(assembler.push(buildPushAdvertFrame()));
          }
        }

        frames.addAll(assembler.push(buildEndOfContactsFrame(lastmod: 42)));

        final contacts = frames
            .map(parseRadioContact)
            .whereType<RadioContact>()
            .toList();
        expect(contacts.length, total);

        final starts = frames.where(
          (f) => f.isNotEmpty && f[0] == respCodeContactsStart,
        );
        final ends = frames.where(isEndOfContactsFrame);
        expect(starts.length, 1);
        expect(parseContactsStartTotal(starts.first), total);
        expect(ends.length, 1);

        // Push frames were emitted (not swallowed into contacts).
        final pushes = frames.where(
          (f) => f.isNotEmpty && f[0] == pushCodeNewAdvert,
        );
        expect(pushes.length, greaterThan(0));
      },
    );

    test('drops incomplete contact when a push arrives mid-frame', () {
      final warns = <String>[];
      final assembler = BleFrameAssembler(onWarn: warns.add);
      final first = buildSyntheticContactFrame(index: 1, name: 'Rep1');
      // Only the first 40 bytes of the contact.
      final partial = first.sublist(0, 40);
      expect(assembler.push(partial), isEmpty);

      final out = assembler.push(buildPushAdvertFrame());
      expect(out, isNotEmpty);
      expect(out.first[0], pushCodeNewAdvert);
      expect(warns, isNotEmpty);
      expect(parseRadioContact(out.first), isNull);
    });
  });

  group('collectContactsFromInbound', () {
    test(
      'one-pass completes with exactly one GET_CONTACTS and interleaved PUSH frames ignored',
      () async {
        final controller = StreamController<Uint8List>();
        final progressEvents = <ContactSyncProgress>[];
        final requests = <int?>[];
        const total = 40;

        final future = collectContactsFromInbound(
          inbound: controller.stream,
          sendGetContacts: (since) async {
            requests.add(since);
            controller.add(buildContactsStartFrame(total));
            // Not a contact frame. Must not end the pass or add a row.
            controller.add(Uint8List.fromList([respCodeSelfInfo]));
            controller.add(Uint8List.fromList([respCodeErr, 4]));
            for (var i = 0; i < total; i++) {
              controller.add(
                buildSyntheticContactFrame(
                  index: i,
                  name: 'Rep$i',
                  type: i.isEven ? advTypeRepeater : advTypeChat,
                  lastMod: 1000 + i,
                ),
              );
              if (i % 5 == 4) controller.add(buildPushAdvertFrame());
            }
            controller.add(buildEndOfContactsFrame(lastmod: 1000 + total - 1));
          },
          onProgress: progressEvents.add,
        );

        final result = await future.timeout(const Duration(seconds: 5));
        expect(requests, [null]);
        expect(result.outcome, ContactSyncOutcome.completed);
        expect(result.isComplete, isTrue);
        expect(result.contacts.length, total);
        expect(result.expectedTotal, total);
        expect(result.framesSeen, greaterThan(total));
        expect(progressEvents.last.completed, isTrue);
        expect(progressEvents.last.disconnected, isFalse);
        expect(
          progressEvents.last.statusLabel,
          'Contacts $total/$total complete',
        );
        final chatPrefix = syntheticContactPrefix(1);
        expect(result.contactTypes[chatPrefix], advTypeChat);
        await controller.close();
      },
    );

    test('sends the caller since once and does not request again', () async {
      final controller = StreamController<Uint8List>();
      final requests = <int?>[];

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        initialSince: 42,
        sendGetContacts: (since) async {
          requests.add(since);
          controller.add(buildContactsStartFrame(1));
          controller.add(
            buildSyntheticContactFrame(index: 3, name: 'Rep3', lastMod: 50),
          );
          controller.add(buildPushAdvertFrame());
          controller.add(buildEndOfContactsFrame(lastmod: 50));
        },
      );

      final result = await future.timeout(const Duration(seconds: 5));
      expect(requests, [42]);
      expect(result.outcome, ContactSyncOutcome.completed);
      expect(result.contacts.length, 1);
      await controller.close();
    });

    test(
      'ERR before START is incomplete and does not send a second request',
      () async {
        final controller = StreamController<Uint8List>();
        final requests = <int?>[];
        final progressEvents = <ContactSyncProgress>[];

        final future = collectContactsFromInbound(
          inbound: controller.stream,
          sendGetContacts: (since) async {
            requests.add(since);
            controller.add(Uint8List.fromList([respCodeErr]));
            controller.add(buildPushAdvertFrame());
          },
          onProgress: progressEvents.add,
        );

        final result = await future.timeout(const Duration(seconds: 2));
        expect(requests, [null]);
        expect(result.outcome, ContactSyncOutcome.incomplete);
        expect(result.isComplete, isFalse);
        expect(result.contacts, isEmpty);
        expect(progressEvents.last.incomplete, isTrue);
        expect(progressEvents.last.disconnected, isFalse);
        expect(progressEvents.last.completed, isFalse);
        expect(
          progressEvents.last.statusLabel,
          isNot('Bluetooth disconnected'),
        );
        await controller.close();
      },
    );

    test('disconnect mid-stream is disconnected', () async {
      final controller = StreamController<Uint8List>();
      final requests = <int?>[];
      final progressEvents = <ContactSyncProgress>[];
      const total = 8;

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        sendGetContacts: (since) async {
          requests.add(since);
          controller.add(buildContactsStartFrame(total));
          controller.add(buildSyntheticContactFrame(index: 0, name: 'Rep0'));
          controller.add(buildPushAdvertFrame());
          await controller.close();
        },
        onProgress: progressEvents.add,
      );

      final result = await future.timeout(const Duration(seconds: 2));
      expect(requests, [null]);
      expect(result.outcome, ContactSyncOutcome.disconnected);
      expect(result.isComplete, isFalse);
      expect(result.contacts.length, 1);
      expect(result.expectedTotal, total);
      expect(progressEvents.last.disconnected, isTrue);
      expect(progressEvents.last.incomplete, isFalse);
      expect(progressEvents.last.active, isFalse);
      expect(progressEvents.last.statusLabel, 'Bluetooth disconnected');
    });

    test('linkClosed mid-pass is disconnected and does not retry', () async {
      final controller = StreamController<Uint8List>();
      final link = Completer<void>();
      final requests = <int?>[];
      final progressEvents = <ContactSyncProgress>[];

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        linkClosed: link.future,
        sendGetContacts: (since) async {
          requests.add(since);
          controller.add(buildContactsStartFrame(3));
          controller.add(buildSyntheticContactFrame(index: 2, name: 'Rep2'));
          await pumpEventQueue();
          link.complete();
        },
        onProgress: progressEvents.add,
      );

      final result = await future.timeout(const Duration(seconds: 2));
      expect(requests, [null]);
      expect(result.outcome, ContactSyncOutcome.disconnected);
      expect(result.isComplete, isFalse);
      expect(result.contacts.length, 1);
      expect(progressEvents.last.statusLabel, 'Bluetooth disconnected');
      expect(progressEvents.last.incomplete, isFalse);
      await controller.close();
    });

    test(
      'counts emoji, non-Latin, 1-char, and empty names once per prefix',
      () async {
        const names = <String>['😀', '节点', 'Q', ''];
        final controller = StreamController<Uint8List>.broadcast();
        final future = collectContactsFromInbound(
          inbound: controller.stream,
          sendGetContacts: (since) async {
            controller.add(buildContactsStartFrame(names.length));
            for (var i = 0; i < names.length; i++) {
              controller.add(
                buildSyntheticContactFrame(index: i + 1, name: names[i]),
              );
            }
            // Same public-key prefix as the empty name. Must not add a row.
            controller.add(
              buildSyntheticContactFrame(index: names.length, name: ''),
            );
            controller.add(buildEndOfContactsFrame());
          },
        );

        final result = await future.timeout(const Duration(seconds: 5));
        expect(result.outcome, ContactSyncOutcome.completed);
        expect(result.contacts.length, names.length);
        expect(result.isComplete, isTrue);
        for (var i = 0; i < names.length; i++) {
          final prefix = syntheticContactPrefix(i + 1);
          expect(result.contacts.containsKey(prefix), isTrue);
          expect(result.contacts[prefix], names[i]);
        }
        await controller.close();
      },
    );
  });

  group('parseContactsStartTotal', () {
    test('reads little-endian total', () {
      expect(parseContactsStartTotal(buildContactsStartFrame(732)), 732);
      expect(parseContactsStartTotal(Uint8List.fromList([2])), isNull);
    });

    test('reads the END frame lastmod', () {
      expect(
        parseEndOfContactsLastMod(buildEndOfContactsFrame(lastmod: 99)),
        99,
      );
      expect(parseEndOfContactsLastMod(Uint8List.fromList([4])), isNull);
    });
  });

  testWidgets('contacts page shows Contacts n/total while syncing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ContactsPage(
          contacts: {'AA': 'Rep'},
          syncProgress: ContactSyncProgress(
            active: true,
            received: 441,
            expected: 891,
          ),
        ),
      ),
    );
    expect(find.text('Contacts 441/891'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets(
    'contacts page ends with Contacts n/total complete or incomplete',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ContactsPage(
            contacts: {'AA': 'Rep'},
            syncProgress: ContactSyncProgress(
              active: false,
              received: 829,
              expected: 899,
              incomplete: true,
            ),
          ),
        ),
      );
      expect(find.text('Contacts 829/899 incomplete'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: ContactsPage(
            contacts: {'AA': 'Rep'},
            syncProgress: ContactSyncProgress(
              active: false,
              received: 899,
              expected: 899,
              completed: true,
            ),
          ),
        ),
      );
      expect(find.text('Contacts 899/899 complete'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);

      await tester.pumpWidget(
        const MaterialApp(
          home: ContactsPage(
            contacts: {'AA': 'Rep'},
            syncProgress: ContactSyncProgress(
              active: false,
              received: 3,
              expected: 10,
              disconnected: true,
            ),
          ),
        ),
      );
      expect(find.text('Bluetooth disconnected'), findsOneWidget);
      expect(find.textContaining('incomplete'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );
}
