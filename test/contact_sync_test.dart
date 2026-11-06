import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
  return frame;
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
    test('collects 750 contacts with idle timeout, not a short total timeout', () async {
      final controller = StreamController<Uint8List>.broadcast();
      final progressEvents = <ContactSyncProgress>[];

      final future = collectContactsFromInbound(
        inbound: controller.stream,
        sendGetContacts: () async {
          // Producer: emit start, contacts with small gaps, then end.
          // Gaps of 30ms would exceed a 12s/750 model but are fine for idle=2s.
          controller.add(buildContactsStartFrame(750));
          for (var i = 0; i < 750; i++) {
            controller.add(
              buildSyntheticContactFrame(index: i, name: 'Rep$i'),
            );
            if (i % 10 == 9) {
              controller.add(buildPushAdvertFrame());
            }
            if (i % 50 == 49) {
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
          }
          controller.add(buildEndOfContactsFrame());
        },
        onProgress: progressEvents.add,
        idleTimeout: const Duration(seconds: 2),
        overallTimeout: const Duration(minutes: 2),
      );

      final result = await future;
      expect(result.sawEnd, isTrue);
      expect(result.timedOut, isFalse);
      expect(result.contacts.length, 750);
      expect(result.expectedTotal, 750);
      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last.completed, isTrue);
      await controller.close();
    });

    test('idle timeout fires when frames stop arriving before END', () async {
      final controller = StreamController<Uint8List>.broadcast();
      final future = collectContactsFromInbound(
        inbound: controller.stream,
        sendGetContacts: () async {
          controller.add(buildContactsStartFrame(100));
          for (var i = 0; i < 5; i++) {
            controller.add(buildSyntheticContactFrame(index: i, name: 'Rep$i'));
          }
          // No END frame — wait for idle timeout.
        },
        idleTimeout: const Duration(milliseconds: 200),
        overallTimeout: const Duration(seconds: 5),
      );

      final result = await future.timeout(const Duration(seconds: 3));
      expect(result.timedOut, isTrue);
      expect(result.sawEnd, isFalse);
      expect(result.contacts.length, 5);
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
        sendGetContacts: () async {
          controller.add(buildContactsStartFrame(2));
          controller.add(buildSyntheticContactFrame(index: 0, name: 'Rep0'));
        },
        idleTimeout: const Duration(milliseconds: 200),
        overallTimeout: const Duration(seconds: 3),
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

  });
}
