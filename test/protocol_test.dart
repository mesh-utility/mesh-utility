import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/transport/protocol.dart';

void main() {
  group('BufferReader', () {
    test('readByte reads single byte', () {
      final r = BufferReader(Uint8List.fromList([0x42]));
      expect(r.readByte(), equals(0x42));
    });

    test('readBytes advances pointer', () {
      final r = BufferReader(Uint8List.fromList([1, 2, 3, 4]));
      r.readBytes(2);
      expect(r.remaining, equals(2));
    });

    test('readBytes throws RangeError on overflow', () {
      final r = BufferReader(Uint8List.fromList([1, 2]));
      expect(() => r.readBytes(3), throwsRangeError);
    });

    test('skipBytes reduces remaining', () {
      final r = BufferReader(Uint8List.fromList([1, 2, 3]));
      r.skipBytes(2);
      expect(r.remaining, equals(1));
    });

    test('skipBytes throws RangeError on overflow', () {
      final r = BufferReader(Uint8List.fromList([1]));
      expect(() => r.skipBytes(2), throwsRangeError);
    });

    test('readUInt8 returns correct value', () {
      final r = BufferReader(Uint8List.fromList([0xFF]));
      expect(r.readUInt8(), equals(255));
    });

    test('readInt8 returns negative for high bit set', () {
      final r = BufferReader(Uint8List.fromList([0xFF]));
      expect(r.readInt8(), equals(-1));
    });

    test('readUInt16LE parses little-endian correctly', () {
      final r = BufferReader(Uint8List.fromList([0x01, 0x00]));
      expect(r.readUInt16LE(), equals(1));
    });

    test('readUInt16BE parses big-endian correctly', () {
      final r = BufferReader(Uint8List.fromList([0x00, 0x01]));
      expect(r.readUInt16BE(), equals(1));
    });

    test('readUInt32LE parses 4-byte little-endian', () {
      final r = BufferReader(Uint8List.fromList([0x01, 0x00, 0x00, 0x00]));
      expect(r.readUInt32LE(), equals(1));
    });

    test('readInt32LE handles negative', () {
      // -1 in little-endian int32
      final r = BufferReader(Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF]));
      expect(r.readInt32LE(), equals(-1));
    });

    test('readInt24BE handles positive value', () {
      final r = BufferReader(Uint8List.fromList([0x00, 0x00, 0x05]));
      expect(r.readInt24BE(), equals(5));
    });

    test('readInt24BE handles negative (sign extension)', () {
      final r = BufferReader(Uint8List.fromList([0xFF, 0xFF, 0xFF]));
      expect(r.readInt24BE(), equals(-1));
    });

    test('readString returns UTF-8 decoded content', () {
      final bytes = Uint8List.fromList('hello'.codeUnits);
      final r = BufferReader(bytes);
      expect(r.readString(), equals('hello'));
    });

    test('readCString stops at null terminator', () {
      final r = BufferReader(Uint8List.fromList([104, 105, 0, 99]));
      expect(r.readCString(4), equals('hi'));
    });

    test('readCStringGreedy stops at null terminator', () {
      final r = BufferReader(Uint8List.fromList([104, 105, 0, 99]));
      expect(r.readCStringGreedy(4), equals('hi'));
    });

    test('remaining is zero after reading all bytes', () {
      final r = BufferReader(Uint8List.fromList([1, 2]));
      r.readBytes(2);
      expect(r.remaining, equals(0));
    });

    test('rewind returns pointer to last read position', () {
      final r = BufferReader(Uint8List.fromList([1, 2, 3]));
      r.readByte();
      r.readByte();
      r.rewind();
      expect(r.remaining, equals(2));
    });

    test('resetPointer goes back to start', () {
      final r = BufferReader(Uint8List.fromList([1, 2, 3]));
      r.readBytes(3);
      r.resetPointer();
      expect(r.remaining, equals(3));
    });
  });

  group('BufferWriter', () {
    test('writeByte produces single byte', () {
      final w = BufferWriter();
      w.writeByte(0x42);
      expect(w.toBytes(), equals(Uint8List.fromList([0x42])));
    });

    test('writeUInt16LE writes little-endian', () {
      final w = BufferWriter();
      w.writeUInt16LE(256);
      expect(w.toBytes(), equals(Uint8List.fromList([0x00, 0x01])));
    });

    test('writeUInt32LE writes little-endian', () {
      final w = BufferWriter();
      w.writeUInt32LE(1);
      expect(w.toBytes(), equals(Uint8List.fromList([0x01, 0x00, 0x00, 0x00])));
    });

    test('writeInt32LE writes negative correctly', () {
      final w = BufferWriter();
      w.writeInt32LE(-1);
      expect(w.toBytes(), equals(Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF])));
    });

    test('writeString encodes UTF-8', () {
      final w = BufferWriter();
      w.writeString('hi');
      expect(w.toBytes(), equals(Uint8List.fromList([104, 105])));
    });

    test('writeCString pads to maxLength with null bytes', () {
      final w = BufferWriter();
      w.writeCString('hi', 5);
      final bytes = w.toBytes();
      expect(bytes.length, equals(5));
      expect(bytes[0], equals(104)); // h
      expect(bytes[1], equals(105)); // i
      expect(bytes[2], equals(0)); // null padding
    });

    test('round-trip: write then read UInt32LE', () {
      final w = BufferWriter();
      w.writeUInt32LE(305419896); // 0x12345678
      final r = BufferReader(w.toBytes());
      expect(r.readUInt32LE(), equals(305419896));
    });

    test('round-trip: write then read Int32LE negative', () {
      final w = BufferWriter();
      w.writeInt32LE(-42);
      final r = BufferReader(w.toBytes());
      expect(r.readInt32LE(), equals(-42));
    });

    test('round-trip: write then read UInt16LE', () {
      final w = BufferWriter();
      w.writeUInt16LE(1000);
      final r = BufferReader(w.toBytes());
      expect(r.readUInt16LE(), equals(1000));
    });
  });

  group('Node discover parsing', () {
    test('parseNodeDiscoverResponse parses control frame fields', () {
      final frame = Uint8List.fromList([
        pushCodeControlData,
        0xF4, // snr=-3.0
        0xC1, // rssi=-63
        0x00, // reserved
        controlNodeDiscoverRespMask | 0x02, // payload type + nodeType
        0x30, // snrIn=12.0
        0x71,
        0x8D,
        0x34,
        0x9F, // tag
        // pubkey prefix (first 8)
        0x10,
        0x52,
        0xA9,
        0x30,
        0xAA,
        0xBB,
        0xCC,
        0xDD,
      ]);

      final parsed = parseNodeDiscoverResponse(frame);
      expect(parsed, isNotNull);
      expect(parsed!.rssi, equals(-63));
      expect(parsed.snr, equals(-3.0));
      expect(parsed.snrIn, equals(12.0));
      expect(parsed.nodeType, equals(2));
      expect(parsed.tagHex, equals('718d349f'));
      expect(parsed.publicKeyPrefix, equals('1052A930AABBCCDD'));
    });

    test('parseNodeDiscoverAdvertResponse parses compact advert (0x8F)', () {
      final payload = <int>[0x10, 0x52, 0xA9, 0x30, 0xAA, 0xBB, 0xCC, 0xDD];
      final frame = Uint8List.fromList([
        pushCodeAdvertCompact,
        0x00,
        0x00,
        payload.length,
        ...payload,
      ]);

      final parsed = parseNodeDiscoverAdvertResponse(frame);
      expect(parsed, isNotNull);
      expect(parsed!.publicKeyPrefix, equals('1052A930AABBCCDD'));
      expect(parsed.name, equals(''));
      expect(parsed.nodeType, equals(0));
    });

    test('parseNodeDiscoverAdvertResponse parses advert name from payload', () {
      final payload = Uint8List(132);
      payload.setAll(0, const [0x10, 0x52, 0xA9, 0x30, 0xAA, 0xBB, 0xCC, 0xDD]);
      payload[32] = advTypeRepeater;
      payload.setAll(99, 'KD3CGK TDECK'.codeUnits);

      final frame = Uint8List.fromList([
        pushCodeNewAdvert,
        0x00,
        0x00,
        payload.length,
        ...payload,
      ]);

      final parsed = parseNodeDiscoverAdvertResponse(frame);
      expect(parsed, isNotNull);
      expect(parsed!.publicKeyPrefix, equals('1052A930AABBCCDD'));
      expect(parsed.name, equals('KD3CGK TDECK'));
      expect(parsed.nodeType, equals(advTypeRepeater));
    });

    test('parseNodeDiscoverAdvertResponse ignores RX log frame (0x88)', () {
      final frame = Uint8List.fromList([
        pushCodeLogRxData,
        0x30,
        0xBF,
        0x2E,
        0x00,
        0x92,
      ]);

      expect(parseNodeDiscoverAdvertResponse(frame), isNull);
    });
  });
}
