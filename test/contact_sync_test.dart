import 'dart:async';
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
  final nameBytes = name.codeUnits;
  final max = maxNameSize - 1;
  final len = nameBytes.length > max ? max : nameBytes.length;
  for (var i = 0; i < len; i++) {
    frame[contactNameOffset + i] = nameBytes[i];
  }
  frame[contactNameOffset + len] = 0;
  frame.setRange(contactLastModOffset, contactLastModOffset + 4, _le32(lastMod));
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
    test('reassembles chunked contacts and survives interleaved push frames', () {
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

      final starts = frames.where((f) => f.isNotEmpty && f[0] == respCodeContactsStart);
      final ends = frames.where(isEndOfContactsFrame);
      expect(starts.length, 1);
      expect(parseContactsStartTotal(starts.first), total);
      expect(ends.length, 1);

      // Push frames were emitted (not swallowed into contacts).
      final pushes = frames.where((f) => f.isNotEmpty && f[0] == pushCodeNewAdvert);
      expect(pushes.length, greaterThan(0));
    });

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
    test('collects 900 contacts across stalls and interleaved pushes', () async {
      final controller = StreamController<Uint8List>.broadcast();
      final progressEvents = <ContactSyncProgress>[];
      final requests = <int?>[];
      const total = 900;

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        sendGetContacts: (since) async {
          requests.add(since);
          // Gaps of 80ms would trip a short total timeout. A push between
          // the two halves of a stall must reset the per-frame idle timer.
          controller.add(buildContactsStartFrame(total));
          for (var i = 0; i < total; i++) {
            controller.add(
              buildSyntheticContactFrame(
                index: i,
                name: 'Rep$i',
                lastMod: 1000 + i,
              ),
            );
            if (i % 10 == 9) {
              controller.add(buildPushAdvertFrame());
            }
            if (i % 100 == 99) {
              await Future<void>.delayed(const Duration(milliseconds: 80));
              controller.add(buildPushAdvertFrame());
              await Future<void>.delayed(const Duration(milliseconds: 80));
            }
          }
          controller.add(buildEndOfContactsFrame(lastmod: 1000 + total - 1));
        },
        onProgress: progressEvents.add,
        idleTimeout: const Duration(milliseconds: 150),
        maxAttempts: 2,
        retryDelay: Duration.zero,
      );

      final result = await future.timeout(const Duration(seconds: 20));
      expect(requests, [null]);
      expect(result.sawEnd, isTrue);
      expect(result.timedOut, isFalse);
      expect(result.contacts.length, total);
      expect(result.expectedTotal, total);
      expect(result.newestLastMod, 1000 + total - 1);
      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last.completed, isTrue);
      expect(progressEvents.last.progressLabel, 'Contacts $total/$total');
      final parsed = parseRadioContact(
        buildSyntheticContactFrame(index: 7, name: 'Rep7', lastMod: 4242),
      );
      expect(parsed!.lastMod, 4242);
      await controller.close();
    });

    test('resumes a mid-sync stop from the newest stored lastmod', () async {
      final controller = StreamController<Uint8List>.broadcast();
      final requests = <int?>[];
      final store = <String, String>{};
      final storeLastMods = <String, int>{};
      final storeSizesAtRequest = <int>[];
      const total = 900;
      const firstBatch = 440;

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        sendGetContacts: (since) async {
          storeSizesAtRequest.add(store.length);
          requests.add(since);
          if (requests.length == 1) {
            controller.add(buildContactsStartFrame(total));
            for (var i = 0; i < firstBatch; i++) {
              controller.add(
                buildSyntheticContactFrame(
                  index: i,
                  name: 'Rep$i',
                  type: i.isEven ? advTypeRepeater : advTypeChat,
                  lastMod: 1000 + i,
                ),
              );
              if (i % 10 == 9) controller.add(buildPushAdvertFrame());
            }
            return;
          }
          final threshold = since ?? 0;
          for (var i = 0; i < total; i++) {
            final lastMod = 1000 + i;
            if (lastMod <= threshold) continue;
            controller.add(
              buildSyntheticContactFrame(
                index: i,
                name: 'Rep$i',
                type: i.isEven ? advTypeRepeater : advTypeRoom,
                lastMod: lastMod,
              ),
            );
            if (i % 17 == 0) controller.add(buildPushAdvertFrame());
          }
          controller.add(buildEndOfContactsFrame(lastmod: 1000 + total - 1));
        },
        onContacts: (batch) async {
          for (final contact in batch) {
            store[contact.publicKeyPrefix] = contact.name;
            if (contact.lastMod > 0) {
              storeLastMods[contact.publicKeyPrefix] = contact.lastMod;
            }
          }
        },
        idleTimeout: const Duration(milliseconds: 200),
        retryDelay: const Duration(milliseconds: 20),
        maxAttempts: 3,
        checkpointEvery: 25,
      );

      final result = await future.timeout(const Duration(seconds: 10));
      expect(requests, [null, 1000 + firstBatch - 1]);
      expect(storeSizesAtRequest, [0, firstBatch]);
      expect(result.sawEnd, isTrue);
      expect(result.timedOut, isFalse);
      expect(result.contacts.length, total);
      expect(result.expectedTotal, total);
      expect(store.length, total);
      expect(storeLastMods.length, total);
      expect(storeLastMods.values.reduce((a, b) => a > b ? a : b), 1000 + total - 1);
      // Companion names are stored locally; the sync result keeps their types.
      final chatPrefix = syntheticContactPrefix(1);
      expect(result.contactTypes[chatPrefix], advTypeChat);
      await controller.close();
    });

    test('full dump follows a since-filter that ends short of the total', () async {
      final controller = StreamController<Uint8List>.broadcast();
      final requests = <int?>[];
      const total = 10;
      final seedContacts = <String, String>{};
      final seedTypes = <String, int>{};
      final seedLastMods = <String, int>{};
      for (var i = 0; i < 4; i++) {
        final frame = buildSyntheticContactFrame(
          index: i,
          name: 'Rep$i',
          lastMod: i + 1,
        );
        final parsed = parseRadioContact(frame)!;
        seedContacts[parsed.publicKeyPrefix] = parsed.name;
        seedTypes[parsed.publicKeyPrefix] = parsed.type;
        seedLastMods[parsed.publicKeyPrefix] = parsed.lastMod;
      }

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        initialSince: 4,
        seedContacts: seedContacts,
        seedTypes: seedTypes,
        seedLastMods: seedLastMods,
        sendGetContacts: (since) async {
          requests.add(since);
          if (requests.length == 1) {
            controller.add(buildContactsStartFrame(total));
            for (var i = 4; i < 6; i++) {
              controller.add(
                buildSyntheticContactFrame(
                  index: i,
                  name: 'Rep$i',
                  lastMod: i + 1,
                ),
              );
            }
            controller.add(buildEndOfContactsFrame(lastmod: 6));
            return;
          }
          controller.add(buildContactsStartFrame(total));
          for (var i = 0; i < total; i++) {
            controller.add(
              buildSyntheticContactFrame(
                index: i,
                name: 'Rep$i',
                lastMod: i + 1,
              ),
            );
            if (i == 3) controller.add(buildPushAdvertFrame());
          }
          controller.add(buildEndOfContactsFrame(lastmod: total));
        },
        idleTimeout: const Duration(seconds: 2),
        retryDelay: Duration.zero,
        maxAttempts: 3,
      );

      final result = await future.timeout(const Duration(seconds: 5));
      expect(requests, [4, null]);
      expect(result.sawEnd, isTrue);
      expect(result.timedOut, isFalse);
      expect(result.contacts.length, total);
      expect(result.expectedTotal, total);
      await controller.close();
    });

    test('idle timeout fires when frames stop arriving before END', () async {
      final controller = StreamController<Uint8List>.broadcast();
      final future = collectContactsFromInbound(
        inbound: controller.stream,
        sendGetContacts: (since) async {
          controller.add(buildContactsStartFrame(100));
          for (var i = 0; i < 5; i++) {
            controller.add(buildSyntheticContactFrame(index: i, name: 'Rep$i'));
          }
          // No END frame — wait for idle timeout.
        },
        idleTimeout: const Duration(milliseconds: 200),
        retryDelay: const Duration(milliseconds: 20),
        maxAttempts: 2,
      );

      final result = await future.timeout(const Duration(seconds: 3));
      expect(result.timedOut, isTrue);
      expect(result.sawEnd, isFalse);
      expect(result.contacts.length, 5);
      expect(result.isComplete, isFalse);
      await controller.close();
    });

    test('end frame arriving short is incomplete and keeps progress up', () async {
      final controller = StreamController<Uint8List>.broadcast();
      final requests = <int?>[];
      final progressEvents = <ContactSyncProgress>[];
      const total = 10;
      const partial = 6;

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        sendGetContacts: (since) async {
          requests.add(since);
          controller.add(buildContactsStartFrame(total));
          for (var i = 0; i < partial; i++) {
            controller.add(
              buildSyntheticContactFrame(
                index: i,
                name: 'Rep$i',
                lastMod: 1000 + i,
              ),
            );
          }
          controller.add(buildEndOfContactsFrame(lastmod: 1000 + partial - 1));
        },
        onProgress: progressEvents.add,
        idleTimeout: const Duration(seconds: 2),
        retryDelay: Duration.zero,
        maxAttempts: 3,
      );

      final result = await future.timeout(const Duration(seconds: 5));
      // Full dump ends short, since resume adds nothing new, then one full
      // dump still ends short. END is not success while stored < total.
      expect(requests, [null, 1000 + partial - 1, null]);
      expect(result.sawEnd, isTrue);
      expect(result.timedOut, isFalse);
      expect(result.attempts, 3);
      expect(result.contacts.length, partial);
      expect(result.expectedTotal, total);
      expect(result.isComplete, isFalse);
      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last.active, isFalse);
      expect(progressEvents.last.incomplete, isTrue);
      expect(progressEvents.last.completed, isFalse);
      expect(
        progressEvents.last.statusLabel,
        'Contacts $partial/$total incomplete',
      );
      for (final event in progressEvents.take(progressEvents.length - 1)) {
        expect(event.active, isTrue);
        expect(event.completed, isFalse);
      }
      await controller.close();
    });

    test('out-of-order lastmod is recovered by a full dump', () async {
      final controller = StreamController<Uint8List>.broadcast();
      final requests = <int?>[];
      const total = 4;
      // Not sorted by arrival. Newest lastmod is the first contact, so a
      // since resume skips the contact that has not been sent yet.
      const lastMods = <int>[80, 10, 50, 20];
      const missingIndex = 3;

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        sendGetContacts: (since) async {
          requests.add(since);
          controller.add(buildContactsStartFrame(total));
          if (requests.length == 1) {
            for (var i = 0; i < missingIndex; i++) {
              controller.add(
                buildSyntheticContactFrame(
                  index: i,
                  name: 'Rep$i',
                  lastMod: lastMods[i],
                ),
              );
            }
            controller.add(buildEndOfContactsFrame(lastmod: lastMods.first));
            return;
          }
          if (since != null) {
            for (var i = 0; i < total; i++) {
              if (lastMods[i] <= since) continue;
              controller.add(
                buildSyntheticContactFrame(
                  index: i,
                  name: 'Rep$i',
                  lastMod: lastMods[i],
                ),
              );
            }
            controller.add(buildEndOfContactsFrame(lastmod: since));
            return;
          }
          for (var i = 0; i < total; i++) {
            controller.add(
              buildSyntheticContactFrame(
                index: i,
                name: 'Rep$i',
                lastMod: lastMods[i],
              ),
            );
          }
          controller.add(buildEndOfContactsFrame(lastmod: lastMods.first));
        },
        idleTimeout: const Duration(seconds: 2),
        retryDelay: Duration.zero,
        maxAttempts: 4,
      );

      final result = await future.timeout(const Duration(seconds: 5));
      expect(requests, [null, lastMods.first, null]);
      expect(result.isComplete, isTrue);
      expect(result.contacts.length, total);
      final missing = syntheticContactPrefix(missingIndex);
      expect(result.contacts[missing], 'Rep$missingIndex');
      expect(result.lastMods[missing], lastMods[missingIndex]);
      await controller.close();
    });

    test('since resume that adds no contacts falls back to a full dump', () async {
      final controller = StreamController<Uint8List>.broadcast();
      final requests = <int?>[];
      final progressEvents = <ContactSyncProgress>[];
      const total = 5;
      final seedContacts = <String, String>{};
      final seedTypes = <String, int>{};
      final seedLastMods = <String, int>{};
      for (var i = 0; i < 2; i++) {
        final frame = buildSyntheticContactFrame(
          index: i,
          name: 'Rep$i',
          lastMod: i == 0 ? 10 : 40,
        );
        final parsed = parseRadioContact(frame)!;
        seedContacts[parsed.publicKeyPrefix] = parsed.name;
        seedTypes[parsed.publicKeyPrefix] = parsed.type;
        seedLastMods[parsed.publicKeyPrefix] = parsed.lastMod;
      }

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        initialSince: 40,
        seedContacts: seedContacts,
        seedTypes: seedTypes,
        seedLastMods: seedLastMods,
        sendGetContacts: (since) async {
          requests.add(since);
          controller.add(buildContactsStartFrame(total));
          if (since != null) {
            controller.add(buildEndOfContactsFrame(lastmod: since));
            return;
          }
          for (var i = 0; i < total; i++) {
            controller.add(
              buildSyntheticContactFrame(
                index: i,
                name: 'Rep$i',
                lastMod: 10 + i,
              ),
            );
          }
          controller.add(buildEndOfContactsFrame(lastmod: 10 + total - 1));
        },
        onProgress: progressEvents.add,
        idleTimeout: const Duration(seconds: 2),
        retryDelay: Duration.zero,
        maxAttempts: 3,
      );

      final result = await future.timeout(const Duration(seconds: 5));
      expect(requests, [40, null]);
      expect(result.sawEnd, isTrue);
      expect(result.timedOut, isFalse);
      expect(result.isComplete, isTrue);
      expect(result.contacts.length, total);
      expect(result.expectedTotal, total);
      expect(progressEvents.last.statusLabel, 'Contacts $total/$total complete');
      expect(progressEvents.last.active, isFalse);
      for (final event in progressEvents.take(progressEvents.length - 1)) {
        expect(event.active, isTrue);
      }
      await controller.close();
    });
  });

  group('parseContactsStartTotal', () {
    test('reads little-endian total', () {
      expect(parseContactsStartTotal(buildContactsStartFrame(732)), 732);
      expect(parseContactsStartTotal(Uint8List.fromList([2])), isNull);
    });

    test('PUSH frames reset idle so sync survives advert gaps', () async {
      final controller = StreamController<Uint8List>();
      final start = DateTime.now();
      final future = collectContactsFromInbound(
        inbound: controller.stream,
        sendGetContacts: (since) async {
          controller.add(buildContactsStartFrame(2));
          controller.add(buildSyntheticContactFrame(index: 0, name: 'Rep0'));
        },
        idleTimeout: const Duration(milliseconds: 200),
        maxAttempts: 1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      controller.add(buildPushAdvertFrame());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      controller.add(buildPushAdvertFrame());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      controller.add(buildSyntheticContactFrame(index: 1, name: 'Rep1'));
      controller.add(buildEndOfContactsFrame());
      final result = await future;
      await controller.close();
      expect(result.sawEnd, isTrue);
      expect(result.contacts.length, 2);
      expect(DateTime.now().difference(start).inMilliseconds, greaterThan(200));
    });

    test('reads the END frame lastmod', () {
      expect(parseEndOfContactsLastMod(buildEndOfContactsFrame(lastmod: 99)), 99);
      expect(parseEndOfContactsLastMod(Uint8List.fromList([4])), isNull);
    });
  });

  testWidgets('contacts page shows Contacts n/total while syncing', (tester) async {
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

  testWidgets('contacts page ends with Contacts n/total complete or incomplete', (
    tester,
  ) async {
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
  });
}
