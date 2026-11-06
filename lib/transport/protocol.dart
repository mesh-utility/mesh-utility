import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mesh_utility/transport/transport_core.dart';

// Buffer Reader - sequential binary data reader with pointer tracking
class BufferReader {
  int _pointer = 0;
  int _lastPointer = 0;
  final Uint8List _buffer;

  BufferReader(Uint8List data) : _buffer = Uint8List.fromList(data);

  int get remaining => _buffer.length - _pointer;

  int readByte() => readBytes(1)[0];

  Uint8List readBytes(int count) {
    _lastPointer = _pointer;
    if (_pointer + count > _buffer.length) {
      throw RangeError(
        'Attempted to read $count bytes at offset $_pointer, but only $remaining bytes remaining in buffer of length ${_buffer.length}',
      );
    }
    final data = _buffer.sublist(_pointer, _pointer + count);
    _pointer += count;
    return data;
  }

  void skipBytes(int count) {
    _lastPointer = _pointer;
    if (_pointer + count > _buffer.length) {
      throw RangeError(
        'Attempted to skip $count bytes at offset $_pointer, but only $remaining bytes remaining in buffer of length ${_buffer.length}',
      );
    }
    _pointer += count;
  }

  Uint8List readRemainingBytes() => readBytes(remaining);

  String readString() {
    _lastPointer = _pointer;
    final value = readRemainingBytes();
    try {
      return utf8.decode(Uint8List.fromList(value), allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(value);
    }
  }

  String readCStringGreedy(int maxLength) {
    _lastPointer = _pointer;
    final value = <int>[];
    final bytes = readBytes(maxLength);
    for (final byte in bytes) {
      if (byte == 0) break;
      value.add(byte);
    }
    try {
      return utf8.decode(Uint8List.fromList(value), allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(value);
    }
  }

  String readCString(int maxLength) {
    final backupPointer = _pointer;
    final value = <int>[];
    var counter = 0;
    while (counter < maxLength) {
      final byte = readByte();
      if (byte == 0) break;
      value.add(byte);
      counter++;
    }
    _lastPointer = backupPointer;
    try {
      return utf8.decode(Uint8List.fromList(value), allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(value);
    }
  }

  int readUInt8() => readBytes(1).buffer.asByteData().getUint8(0);
  int readInt8() => readBytes(1).buffer.asByteData().getInt8(0);
  int readUInt16LE() =>
      readBytes(2).buffer.asByteData().getUint16(0, Endian.little);
  int readUInt16BE() =>
      readBytes(2).buffer.asByteData().getUint16(0, Endian.big);
  int readUInt32LE() =>
      readBytes(4).buffer.asByteData().getUint32(0, Endian.little);
  int readUInt32BE() =>
      readBytes(4).buffer.asByteData().getUint32(0, Endian.big);
  int readInt16LE() =>
      readBytes(2).buffer.asByteData().getInt16(0, Endian.little);
  int readInt16BE() => readBytes(2).buffer.asByteData().getInt16(0, Endian.big);
  int readInt32LE() =>
      readBytes(4).buffer.asByteData().getInt32(0, Endian.little);

  int readInt24BE() {
    var value = (readByte() << 16) | (readByte() << 8) | readByte();
    if ((value & 0x800000) != 0) value -= 0x1000000;
    return value;
  }

  void resetPointer() => _pointer = 0;
  void rewind() => _pointer = _lastPointer;
}

// Buffer Writer - accumulating binary data builder
class BufferWriter {
  final BytesBuilder _builder = BytesBuilder();

  Uint8List toBytes() => _builder.toBytes();

  void writeByte(int byte) => _builder.addByte(byte);
  void writeBytes(Uint8List bytes) => _builder.add(bytes);

  void writeUInt16LE(int num) {
    final bytes = Uint8List(2)
      ..buffer.asByteData().setUint16(0, num, Endian.little);
    writeBytes(bytes);
  }

  void writeUInt32LE(int num) {
    final bytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, num, Endian.little);
    writeBytes(bytes);
  }

  void writeInt32LE(int num) {
    final bytes = Uint8List(4)
      ..buffer.asByteData().setInt32(0, num, Endian.little);
    writeBytes(bytes);
  }

  void writeString(String string) =>
      writeBytes(Uint8List.fromList(utf8.encode(string)));

  void writeCString(String string, int maxLength) {
    final bytes = Uint8List(maxLength);
    final encoded = utf8.encode(string);
    for (var i = 0; i < maxLength - 1 && i < encoded.length; i++) {
      bytes[i] = encoded[i];
    }
    writeBytes(bytes);
  }

  void writeHex(String hex) {
    writeBytes(hex2Uint8List(hex));
  }
}

Uint8List hex2Uint8List(String hex) {
  if (hex.isEmpty || hex.length.isOdd) {
    throw FormatException('Invalid hex string length: ${hex.length}');
  }
  final result = <int>[];
  for (var i = 0; i < hex.length ~/ 2; i++) {
    final hexByte = hex.substring(i * 2, i * 2 + 2);
    final byte = int.tryParse(hexByte, radix: 16);
    if (byte == null) {
      throw FormatException('Invalid hex characters at position $i: $hexByte');
    }
    result.add(byte);
  }
  return Uint8List.fromList(result);
}

// Command codes (to device)
const int cmdAppStart = 1;
const int cmdSendTxtMsg = 2;
const int cmdSendChannelTxtMsg = 3;
const int cmdGetContacts = 4;
const int cmdGetDeviceTime = 5;
const int cmdSetDeviceTime = 6;
const int cmdSendSelfAdvert = 7;
const int cmdSetAdvertName = 8;
const int cmdAddUpdateContact = 9;
const int cmdSyncNextMessage = 10;
const int cmdSetRadioParams = 11;
const int cmdSetRadioTxPower = 12;
const int cmdResetPath = 13;
const int cmdSetAdvertLatLon = 14;
const int cmdRemoveContact = 15;
const int cmdShareContact = 16;
const int cmdExportContact = 17;
const int cmdImportContact = 18;
const int cmdReboot = 19;
const int cmdGetBattAndStorage = 20;
const int cmdDeviceQuery = 22;
const int cmdSendLogin = 26;
const int cmdSendStatusReq = 27;
const int cmdGetContactByKey = 30;
const int cmdGetChannel = 31;
const int cmdSetChannel = 32;
const int cmdSignStart = 33;
const int cmdSignData = 34;
const int cmdSignFinish = 35;
const int cmdSendTracePath = 36;
const int cmdGetTelemetryReq = 39;
const int cmdGetCustomVar = 40;
const int cmdSetCustomVar = 41;
const int cmdSendBinaryReq = 50;
const int cmdSendControlData = 55;
const int cmdSendAnonReq = 57;
const int cmdSetAutoAddConfig = 58;
const int cmdGetAutoAddConfig = 59;
const int cmdSetOtherParams = 38;

// Text message types
const int txtTypePlain = 0;
const int txtTypeCliData = 1;

// Repeater request types
const int reqTypeGetStatus = 0x01;
const int reqTypeKeepAlive = 0x02;
const int reqTypeGetTelemetry = 0x03;
const int reqTypeGetAccessList = 0x05;
const int reqTypeGetNeighbors = 0x06;

// Repeater response codes
const int respServerLoginOk = 0;

// Response codes (from device)
const int respCodeOk = 0;
const int respCodeErr = 1;
const int respCodeContactsStart = 2;
const int respCodeContact = 3;
const int respCodeEndOfContacts = 4;
const int respCodeSelfInfo = 5;
const int respCodeSent = 6;
const int respCodeContactMsgRecv = 7;
const int respCodeChannelMsgRecv = 8;
const int respCodeCurrTime = 9;
const int respCodeNoMoreMessages = 10;
const int respCodeExportContact = 11;
const int respCodeBattAndStorage = 12;
const int respCodeDeviceInfo = 13;
const int respCodeContactMsgRecvV3 = 16;
const int respCodeChannelMsgRecvV3 = 17;
const int respCodeChannelInfo = 18;
const int respCodeSignStart = 19;
const int respCodeSignature = 20;
const int respCodeCustomVars = 21;
const int respCodeAutoAddConfig = 25;

// Push codes (async from device)
const int pushCodeAdvert = 0x80;
const int pushCodePathUpdated = 0x81;
const int pushCodeSendConfirmed = 0x82;
const int pushCodeMsgWaiting = 0x83;
const int pushCodeLoginSuccess = 0x85;
const int pushCodeLoginFail = 0x86;
const int pushCodeStatusResponse = 0x87;
const int pushCodeLogRxData = 0x88;
const int pushCodeTraceData = 0x89;
const int pushCodeNewAdvert = 0x8A;
const int pushCodeTelemetryResponse = 0x8B;
const int pushCodeBinaryResponse = 0x8C;
const int pushCodeControlData = 0x8E;
const int pushCodeAdvertCompact = 0x8F;

// Contact/advertisement types
const int advTypeChat = 1;
const int advTypeRepeater = 2;
const int advTypeRoom = 3;
const int advTypeSensor = 4;

// Payload Types
const int payloadTypeREQ = 0x00;
const int payloadTypeRESPONSE = 0x01;
const int payloadTypeTXTMSG = 0x02;
const int payloadTypeACK = 0x03;
const int payloadTypeADVERT = 0x04;
const int payloadTypeGRPTXT = 0x05;
const int payloadTypeGRPDATA = 0x06;
const int payloadTypeANONREQ = 0x07;
const int payloadTypePATH = 0x08;
const int payloadTypeTRACE = 0x09;
const int payloadTypeMULTIPART = 0x0A;
const int payloadTypeCONTROL = 0x0B;
const int payloadTypeRawCustom = 0x0F;

// auto-add flags
const int autoAddOverwriteOldestFlag = 1 << 0;
const int autoAddChatFlag = 1 << 1;
const int autoAddRepeaterFlag = 1 << 2;
const int autoAddRoomServerFlag = 1 << 3;
const int autoAddSensorFlag = 1 << 4;

// Sizes
const int pubKeySize = 32;
const int maxPathSize = 64;
const int pathHashSize = 1;
const int maxNameSize = 32;
const int maxFrameSize = 172;
const int appProtocolVersion = 3;
const int maxTextPayloadBytes = 160;
const int _sendTextMsgOverheadBytes = 1 + 1 + 1 + 4 + 6 + 1 + 2;
const int _sendChannelTextMsgOverheadBytes = 1 + 1 + 1 + 4 + 1 + 2;

int maxContactMessageBytes() {
  final byFrame = maxFrameSize - _sendTextMsgOverheadBytes;
  return _minPositive(byFrame, maxTextPayloadBytes);
}

int maxChannelMessageBytes(String? senderName) {
  final nameLength = _senderNameBytes(senderName);
  final prefixBytes = nameLength + 2;
  final byPayload = maxTextPayloadBytes - prefixBytes;
  final byFrame = maxFrameSize - _sendChannelTextMsgOverheadBytes;
  return _minPositive(byPayload, byFrame);
}

int _senderNameBytes(String? senderName) {
  if (senderName == null || senderName.isEmpty) return maxNameSize - 1;
  final bytes = utf8.encode(senderName);
  final maxBytes = maxNameSize - 1;
  return bytes.length > maxBytes ? maxBytes : bytes.length;
}

int _minPositive(int a, int b) {
  final minValue = a < b ? a : b;
  return minValue < 0 ? 0 : minValue;
}

// Contact frame offsets
const int contactPubKeyOffset = 1;
const int contactTypeOffset = 33;
const int contactFlagsOffset = 34;
const int contactFlagFavorite = 0x01;
const int contactPathLenOffset = 35;
const int contactPathOffset = 36;
const int contactNameOffset = 100;
const int contactTimestampOffset = 132;
const int contactLatOffset = 136;
const int contactLonOffset = 140;
const int contactLastModOffset = 144;
const int contactFrameSize = 148;

// Message frame offsets
const int msgPubKeyOffset = 1;
const int msgTimestampOffset = 33;
const int msgFlagsOffset = 37;
const int msgTextOffset = 38;

class ParsedContactText {
  final Uint8List senderPrefix;
  final String text;

  const ParsedContactText({required this.senderPrefix, required this.text});
}

class RadioContact {
  const RadioContact({required this.publicKeyPrefix, required this.name});

  final String publicKeyPrefix;
  final String name;
}

ParsedContactText? parseContactMessageText(Uint8List frame) {
  if (frame.isEmpty) return null;
  final code = frame[0];
  if (code != respCodeContactMsgRecv && code != respCodeContactMsgRecvV3) {
    return null;
  }

  final isV3 = code == respCodeContactMsgRecvV3;
  final prefixOffset = isV3 ? 4 : 1;
  const prefixLen = 6;
  final txtTypeOffset = prefixOffset + prefixLen + 1;
  final timestampOffset = txtTypeOffset + 1;
  final baseTextOffset = timestampOffset + 4;
  if (frame.length <= baseTextOffset) return null;

  final flags = frame[txtTypeOffset];
  final shiftedType = flags >> 2;
  final rawType = flags;
  final isPlain = shiftedType == txtTypePlain || rawType == txtTypePlain;
  final isCli = shiftedType == txtTypeCliData || rawType == txtTypeCliData;
  if (!isPlain && !isCli) {
    return null;
  }

  var text = readCString(
    frame,
    baseTextOffset,
    frame.length - baseTextOffset,
  ).trim();
  if (text.isEmpty && frame.length > baseTextOffset + 4) {
    text = readCString(
      frame,
      baseTextOffset + 4,
      frame.length - (baseTextOffset + 4),
    ).trim();
  }
  if (text.isEmpty) return null;

  final senderPrefix = frame.sublist(prefixOffset, prefixOffset + prefixLen);
  return ParsedContactText(senderPrefix: senderPrefix, text: text);
}

RadioContact? parseRadioContact(Uint8List frame) {
  if (frame.length < contactFrameSize || frame[0] != respCodeContact) {
    return null;
  }

  final pubKeyEnd = contactPubKeyOffset + 32;
  if (frame.length < pubKeyEnd) return null;
  final pubKey = frame.sublist(contactPubKeyOffset, pubKeyEnd);
  final prefixBytes = pubKey.sublist(0, 8);
  final publicKeyPrefix = prefixBytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  final name = _extractBestContactName(frame);
  if (name.isEmpty) return null;

  return RadioContact(publicKeyPrefix: publicKeyPrefix, name: name);
}

String _extractBestContactName(Uint8List frame) {
  String best = '';
  var bestScore = 0;

  // Known/observed layout offsets across protocol variants.
  const candidateOffsets = <int>[contactNameOffset, 112, 108, 104, 96];
  for (final offset in candidateOffsets) {
    final candidate = readCString(
      frame,
      offset,
      (frame.length - offset).clamp(0, maxNameSize),
    ).trim();
    final score = _contactNameScore(candidate);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }

  // Fallback: scan for a likely printable C-string in the latter half.
  final searchStart = frame.length > 72 ? 72 : 0;
  final searchEnd = frame.length > 8 ? frame.length - 8 : frame.length;
  for (var i = searchStart; i < searchEnd; i++) {
    final maxLen = (frame.length - i).clamp(0, maxNameSize);
    if (maxLen < 4) continue;
    final candidate = readCString(frame, i, maxLen).trim();
    final score = _contactNameScore(candidate);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }

  return bestScore >= 8 ? best : '';
}

int _contactNameScore(String value) {
  if (value.isEmpty) return 0;
  if (value.length < 3 || value.length > maxNameSize) return 0;
  if (value.contains('\uFFFD')) return 0;
  const allowed = r'^[A-Za-z0-9 _\-.]+$';
  if (!RegExp(allowed).hasMatch(value)) return 0;

  var score = 0;
  for (final rune in value.runes) {
    final c = rune;
    final isAsciiText =
        (c >= 0x30 && c <= 0x39) || // 0-9
        (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        c == 0x20 || // space
        c == 0x2D || // -
        c == 0x5F || // _
        c == 0x2E; // .
    if (isAsciiText) {
      score += 2;
    } else if (c >= 0x20 && c <= 0x7E) {
      score += 1;
    } else {
      score -= 3;
    }
  }

  final lettersDigits = RegExp(r'[A-Za-z0-9]').allMatches(value).length;
  final letters = RegExp(r'[A-Za-z]').allMatches(value).length;
  if (letters < 2) return 0;
  score += lettersDigits;
  return score;
}

bool isEndOfContactsFrame(Uint8List frame) {
  return frame.isNotEmpty && frame[0] == respCodeEndOfContacts;
}

int readUint32LE(Uint8List data, int offset) {
  return data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);
}

int readUint16LE(Uint8List data, int offset) {
  return data[offset] | (data[offset + 1] << 8);
}

int readInt32LE(Uint8List data, int offset) {
  var val = readUint32LE(data, offset);
  if (val >= 0x80000000) val -= 0x100000000;
  return val;
}

String readCString(Uint8List data, int offset, int maxLen) {
  var end = offset;
  while (end < offset + maxLen && end < data.length && data[end] != 0) {
    end++;
  }
  try {
    return utf8.decode(data.sublist(offset, end), allowMalformed: true);
  } catch (_) {
    return String.fromCharCodes(data.sublist(offset, end));
  }
}

String pubKeyToHex(Uint8List pubKey) {
  return pubKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List hexToPubKey(String hex) {
  final result = Uint8List(pubKeySize);
  for (var i = 0; i < pubKeySize && i * 2 + 1 < hex.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

Uint8List buildGetContactsFrame({int? since}) {
  final writer = BufferWriter();
  writer.writeByte(cmdGetContacts);
  if (since != null) {
    writer.writeUInt32LE(since);
  }
  return writer.toBytes();
}

Uint8List buildSendLoginFrame(Uint8List recipientPubKey, String password) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendLogin);
  writer.writeBytes(recipientPubKey);
  writer.writeString(password);
  writer.writeByte(0);
  return writer.toBytes();
}

Uint8List buildSendStatusRequestFrame(Uint8List recipientPubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendStatusReq);
  writer.writeBytes(recipientPubKey);
  return writer.toBytes();
}

Uint8List buildSendTextMsgFrame(
  Uint8List recipientPubKey,
  String text, {
  int attempt = 0,
  int? timestampSeconds,
}) {
  final timestamp =
      timestampSeconds ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final writer = BufferWriter();
  writer.writeByte(cmdSendTxtMsg);
  writer.writeByte(txtTypePlain);
  writer.writeByte(attempt.clamp(0, 3));
  writer.writeUInt32LE(timestamp);
  writer.writeBytes(recipientPubKey.sublist(0, 6));
  writer.writeString(text);
  writer.writeByte(0);
  return writer.toBytes();
}

Uint8List buildSendChannelTextMsgFrame(int channelIndex, String text) {
  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final writer = BufferWriter();
  writer.writeByte(cmdSendChannelTxtMsg);
  writer.writeByte(txtTypePlain);
  writer.writeByte(channelIndex);
  writer.writeUInt32LE(timestamp);
  writer.writeString(text);
  writer.writeByte(0);
  return writer.toBytes();
}

Uint8List buildRemoveContactFrame(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdRemoveContact);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

Uint8List buildAppStartFrame({
  String appName = 'Mesh Utility',
  int appVersion = 1,
}) {
  final writer = BufferWriter();
  writer.writeByte(cmdAppStart);
  writer.writeByte(appVersion);
  writer.writeBytes(Uint8List(6));
  writer.writeString(appName);
  writer.writeByte(0);
  return writer.toBytes();
}

Uint8List buildDeviceQueryFrame({int appVersion = appProtocolVersion}) {
  return Uint8List.fromList([cmdDeviceQuery, appVersion]);
}

Uint8List buildGetDeviceTimeFrame() {
  return Uint8List.fromList([cmdGetDeviceTime]);
}

Uint8List buildGetBattAndStorageFrame() {
  return Uint8List.fromList([cmdGetBattAndStorage]);
}

Uint8List buildSetDeviceTimeFrame(int timestamp) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetDeviceTime);
  writer.writeUInt32LE(timestamp);
  return writer.toBytes();
}

Uint8List buildSendSelfAdvertFrame({bool flood = false}) {
  return Uint8List.fromList([cmdSendSelfAdvert, flood ? 1 : 0]);
}

Uint8List buildSetAdvertNameFrame(String name) {
  final nameBytes = utf8.encode(name);
  final nameLen = nameBytes.length < maxNameSize
      ? nameBytes.length
      : maxNameSize - 1;
  final writer = BufferWriter();
  writer.writeByte(cmdSetAdvertName);
  writer.writeBytes(Uint8List.fromList(nameBytes.sublist(0, nameLen)));
  return writer.toBytes();
}

Uint8List buildSetAdvertLatLonFrame(double lat, double lon) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetAdvertLatLon);
  writer.writeInt32LE((lat * 1000000).round());
  writer.writeInt32LE((lon * 1000000).round());
  return writer.toBytes();
}

Uint8List buildSetCustomVarFrame(String value) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetCustomVar);
  writer.writeString(value);
  writer.writeByte(0);
  return writer.toBytes();
}

Uint8List buildRebootFrame() {
  return Uint8List.fromList([cmdReboot, ...utf8.encode('reboot')]);
}

Uint8List buildSyncNextMessageFrame() {
  return Uint8List.fromList([cmdSyncNextMessage]);
}

Uint8List buildGetChannelFrame(int channelIndex) {
  return Uint8List.fromList([cmdGetChannel, channelIndex]);
}

Uint8List buildSetChannelFrame(int channelIndex, String name, Uint8List psk) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetChannel);
  writer.writeByte(channelIndex);
  writer.writeCString(name, 32);
  final pskPadded = Uint8List(16);
  for (var i = 0; i < 16 && i < psk.length; i++) {
    pskPadded[i] = psk[i];
  }
  writer.writeBytes(pskPadded);
  return writer.toBytes();
}

Uint8List buildSignStartFrame() {
  return Uint8List.fromList([cmdSignStart]);
}

Uint8List buildSignDataFrame(Uint8List chunk) {
  final writer = BufferWriter();
  writer.writeByte(cmdSignData);
  writer.writeBytes(chunk);
  return writer.toBytes();
}

Uint8List buildSignFinishFrame() {
  return Uint8List.fromList([cmdSignFinish]);
}

Uint8List buildSetRadioParamsFrame(
  int freqHz,
  int bwHz,
  int sf,
  int cr, {
  bool? clientRepeat,
}) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetRadioParams);
  writer.writeUInt32LE(freqHz);
  writer.writeUInt32LE(bwHz);
  writer.writeByte(sf);
  writer.writeByte(cr);
  if (clientRepeat != null) {
    writer.writeByte(clientRepeat ? 1 : 0);
  }
  return writer.toBytes();
}

Uint8List buildSetRadioTxPowerFrame(int powerDbm) {
  return Uint8List.fromList([cmdSetRadioTxPower, powerDbm]);
}

Uint8List buildResetPathFrame(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdResetPath);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

Uint8List buildUpdateContactPathFrame(
  Uint8List pubKey,
  Uint8List customPath,
  int pathLen, {
  int type = 1,
  int flags = 0,
  String name = '',
}) {
  final writer = BufferWriter();
  writer.writeByte(cmdAddUpdateContact);
  writer.writeBytes(pubKey);
  writer.writeByte(type);
  writer.writeByte(flags);
  writer.writeByte(pathLen);

  final pathPadded = Uint8List(maxPathSize);
  if (customPath.isNotEmpty && pathLen > 0) {
    final copyLen = customPath.length < maxPathSize
        ? customPath.length
        : maxPathSize;
    for (var i = 0; i < copyLen; i++) {
      pathPadded[i] = customPath[i];
    }
  }
  writer.writeBytes(pathPadded);

  writer.writeCString(name, maxNameSize);

  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  writer.writeUInt32LE(timestamp);

  return writer.toBytes();
}

Uint8List buildGetContactByKeyFrame(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdGetContactByKey);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

Uint8List buildGetCustomVarsFrame() {
  return Uint8List.fromList([cmdGetCustomVar]);
}

Uint8List buildGetAutoAddFlagsFrame() {
  return Uint8List.fromList([cmdGetAutoAddConfig]);
}

int calculateLoRaAirtime({
  required int payloadBytes,
  required int spreadingFactor,
  required int bandwidthHz,
  required int codingRate,
  int preambleSymbols = 8,
  bool lowDataRateOptimize = false,
  bool explicitHeader = true,
}) {
  final symbolDuration = (1 << spreadingFactor) / (bandwidthHz / 1000.0);
  final preambleTime = (preambleSymbols + 4.25) * symbolDuration;

  final headerBytes = explicitHeader ? 0 : 20;
  const crc = 1;
  final de = lowDataRateOptimize ? 1 : 0;

  final numerator =
      8 * payloadBytes - 4 * spreadingFactor + 28 + 16 * crc - headerBytes;
  final denominator = 4 * (spreadingFactor - 2 * de);
  var payloadSymbols =
      8 + ((numerator / denominator).ceil()) * (codingRate + 4);

  if (payloadSymbols < 0) {
    payloadSymbols = 8;
  }

  final payloadTime = payloadSymbols * symbolDuration;
  return (preambleTime + payloadTime).ceil();
}

int calculateMessageTimeout({
  required int freqHz,
  required int bwHz,
  required int sf,
  required int cr,
  required int pathLength,
  int messageBytes = 100,
}) {
  final airtime = calculateLoRaAirtime(
    payloadBytes: messageBytes,
    spreadingFactor: sf,
    bandwidthHz: bwHz,
    codingRate: cr,
    lowDataRateOptimize: sf >= 11,
  );

  if (pathLength < 0) {
    return 500 + (16 * airtime);
  }

  return 500 + ((airtime * 6 + 250) * (pathLength + 1));
}

Uint8List buildSendCliCommandFrame(
  Uint8List repeaterPubKey,
  String command, {
  int attempt = 0,
  int? timestampSeconds,
}) {
  final timestamp =
      timestampSeconds ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final writer = BufferWriter();
  writer.writeByte(cmdSendTxtMsg);
  writer.writeByte(txtTypeCliData);
  writer.writeByte(attempt.clamp(0, 3));
  writer.writeUInt32LE(timestamp);
  writer.writeBytes(repeaterPubKey.sublist(0, 6));
  writer.writeString(command);
  writer.writeByte(0);
  return writer.toBytes();
}

Uint8List buildSendBinaryReq(Uint8List repeaterPubKey, {Uint8List? payload}) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendBinaryReq);
  writer.writeBytes(repeaterPubKey);
  if (payload != null && payload.isNotEmpty) {
    writer.writeBytes(payload);
  }
  return writer.toBytes();
}

Uint8List buildTraceReq(int tag, int auth, int flag, {Uint8List? payload}) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendTracePath);
  writer.writeUInt32LE(tag);
  writer.writeUInt32LE(auth);
  writer.writeByte(flag);
  if (payload != null && payload.isNotEmpty) {
    writer.writeBytes(payload);
  }
  return writer.toBytes();
}

Uint8List buildExportContactFrame(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdExportContact);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

Uint8List buildImportContactFrame(Uint8List contactFrame) {
  final writer = BufferWriter();
  writer.writeByte(cmdImportContact);
  writer.writeBytes(contactFrame);
  return writer.toBytes();
}

Uint8List buildZeroHopContact(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdShareContact);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

Uint8List buildSetOtherParamsFrame(
  int allowTelemetryFlags,
  int advertLocationPolicy,
  int multiAcks,
) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetOtherParams);
  writer.writeByte(0x01);
  writer.writeByte(allowTelemetryFlags);
  writer.writeByte(advertLocationPolicy);
  writer.writeByte(multiAcks);
  return writer.toBytes();
}

Uint8List buildSetAutoAddConfigFrame({
  required bool autoAddChat,
  required bool autoAddRepeater,
  required bool autoAddRoomServer,
  required bool autoAddSensor,
  required bool overwriteOldest,
}) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetAutoAddConfig);
  var flags = 0;
  if (autoAddChat) flags |= autoAddChatFlag;
  if (autoAddRepeater) flags |= autoAddRepeaterFlag;
  if (autoAddRoomServer) flags |= autoAddRoomServerFlag;
  if (autoAddSensor) flags |= autoAddSensorFlag;
  if (overwriteOldest) flags |= autoAddOverwriteOldestFlag;
  writer.writeByte(flags);
  return writer.toBytes();
}

const int controlNodeDiscoverReq = 0x80;
const int controlNodeDiscoverRespMask = 0x90;

enum ProtocolCommandKind { lifecycle, radioFrame }

abstract class ProtocolCommand {
  const ProtocolCommand(this.name, this.kind);

  final String name;
  final ProtocolCommandKind kind;

  Uint8List encode();

  Future<void> execute(Transport transport) async {
    if (kind == ProtocolCommandKind.lifecycle && this is ConnectCommand) {
      await transport.connect();
      return;
    }

    final payload = encode();
    if (payload.isNotEmpty) {
      await transport.send(payload);
    }
  }
}

class ConnectCommand extends ProtocolCommand {
  const ConnectCommand() : super('connect', ProtocolCommandKind.lifecycle);

  @override
  Uint8List encode() => Uint8List(0);
}

class NodeDiscoverCommand extends ProtocolCommand {
  NodeDiscoverCommand({this.filter = 0xFF, int? tag})
    : tag = tag ?? _randomTag(),
      super('node_discover', ProtocolCommandKind.radioFrame);

  final int filter;
  final int tag;

  @override
  Uint8List encode() {
    final data = Uint8List(7);
    data[0] = cmdSendControlData;
    data[1] = controlNodeDiscoverReq | 0x01;
    data[2] = filter & 0xFF;
    data[3] = tag & 0xFF;
    data[4] = (tag >> 8) & 0xFF;
    data[5] = (tag >> 16) & 0xFF;
    data[6] = (tag >> 24) & 0xFF;
    return data;
  }

  static int _randomTag() => Random().nextInt(0x100000000);
}

class RawFrameCommand extends ProtocolCommand {
  const RawFrameCommand(String name, this.payload)
    : super(name, ProtocolCommandKind.radioFrame);

  final Uint8List payload;

  @override
  Uint8List encode() => payload;
}

class ProtocolCommandRegistry {
  const ProtocolCommandRegistry();

  ProtocolCommand connect() => const ConnectCommand();

  ProtocolCommand nodeDiscover({int filter = 0xFF, int? tag}) =>
      NodeDiscoverCommand(filter: filter, tag: tag);

  ProtocolCommand appStart({
    String appName = 'Mesh Utility',
    int appVersion = 1,
  }) => RawFrameCommand(
    'app_start',
    buildAppStartFrame(appName: appName, appVersion: appVersion),
  );

  ProtocolCommand getContacts({int? since}) =>
      RawFrameCommand('get_contacts', buildGetContactsFrame(since: since));

  ProtocolCommand deviceQuery({int appVersion = appProtocolVersion}) =>
      RawFrameCommand(
        'device_query',
        buildDeviceQueryFrame(appVersion: appVersion),
      );

  ProtocolCommand sendText(
    Uint8List recipientPubKey,
    String text, {
    int attempt = 0,
    int? timestampSeconds,
  }) => RawFrameCommand(
    'send_text',
    buildSendTextMsgFrame(
      recipientPubKey,
      text,
      attempt: attempt,
      timestampSeconds: timestampSeconds,
    ),
  );

  ProtocolCommand custom(String name, Uint8List payload) =>
      RawFrameCommand(name, payload);

  ProtocolCommand signStart() =>
      RawFrameCommand('sign_start', buildSignStartFrame());

  ProtocolCommand signData(Uint8List chunk) =>
      RawFrameCommand('sign_data', buildSignDataFrame(chunk));

  ProtocolCommand signFinish() =>
      RawFrameCommand('sign_finish', buildSignFinishFrame());

  ProtocolCommand setOtherParams({
    required int allowTelemetryFlags,
    required int advertLocationPolicy,
    required int multiAcks,
  }) => RawFrameCommand(
    'set_other_params',
    buildSetOtherParamsFrame(
      allowTelemetryFlags,
      advertLocationPolicy,
      multiAcks,
    ),
  );
}

class NodeDiscoverResponse {
  const NodeDiscoverResponse({
    required this.snr,
    required this.rssi,
    required this.snrIn,
    required this.nodeType,
    required this.tagHex,
    required this.publicKeyPrefix,
    required this.name,
  });

  final double snr;
  final int rssi;
  final double snrIn;
  final int nodeType;
  final String tagHex;
  final String publicKeyPrefix;
  final String name;
}

class NodeDiscoverAdvertResponse {
  const NodeDiscoverAdvertResponse({
    required this.publicKeyPrefix,
    required this.name,
    required this.nodeType,
  });

  final String publicKeyPrefix;
  final String name;
  final int nodeType;
}

NodeDiscoverResponse? parseNodeDiscoverResponse(Uint8List frame) {
  if (frame.length < 5 || frame[0] != pushCodeControlData) {
    return null;
  }

  final frameView = ByteData.sublistView(frame);
  final snr = frameView.getInt8(1) / 4;
  final rssi = frameView.getInt8(2);

  final payload = frame.sublist(4);
  if (payload.length < 6) {
    return null;
  }

  final payloadType = payload[0];
  if ((payloadType & 0xF0) != controlNodeDiscoverRespMask) {
    return null;
  }

  final nodeType = payloadType & 0x0F;
  final snrIn =
      ByteData.sublistView(Uint8List.fromList([payload[1]])).getInt8(0) / 4;

  final tagBytes = payload.sublist(2, 6);
  final tagHex = tagBytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  final pubKeyData = payload.sublist(6);
  final prefixBytes = pubKeyData.length >= 8
      ? pubKeyData.sublist(0, 8)
      : pubKeyData;
  final publicKeyPrefix = prefixBytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  var name = '';
  if (pubKeyData.length > 32) {
    name = String.fromCharCodes(
      pubKeyData.sublist(32),
    ).replaceAll('\u0000', '').trim();
  }

  return NodeDiscoverResponse(
    snr: snr,
    rssi: rssi,
    snrIn: snrIn,
    nodeType: nodeType,
    tagHex: tagHex,
    publicKeyPrefix: publicKeyPrefix,
    name: name,
  );
}

NodeDiscoverAdvertResponse? parseNodeDiscoverAdvertResponse(Uint8List frame) {
  if (frame.length < 5 ||
      (frame[0] != pushCodeNewAdvert &&
          frame[0] != pushCodeAdvert &&
          frame[0] != pushCodeAdvertCompact)) {
    return null;
  }
  final code = frame[0];
  final candidates = <Uint8List>[];
  if (code == pushCodeAdvertCompact) {
    if (frame.length > 4) {
      candidates.add(Uint8List.fromList(frame.sublist(4)));
    }
    if (frame.isNotEmpty) {
      candidates.add(Uint8List.fromList(frame));
    }
  } else {
    final expectedLen = 4 + frame[3];
    if (expectedLen > 4 && expectedLen <= frame.length) {
      candidates.add(Uint8List.fromList(frame.sublist(4, expectedLen)));
    }
    if (frame.length > 4) {
      candidates.add(Uint8List.fromList(frame.sublist(4)));
    }
  }
  if (frame.length > 1) {
    candidates.add(Uint8List.fromList(frame.sublist(1)));
  }

  NodeDiscoverAdvertResponse? best;
  var bestScore = 0;
  for (final payload in candidates) {
    final parsed = _parseNodeDiscoverAdvertPayload(
      payload,
      allowEmptyName: code == pushCodeAdvertCompact,
    );
    if (parsed == null) continue;
    final score =
        _contactNameScore(parsed.name) + parsed.publicKeyPrefix.length;
    if (score > bestScore) {
      bestScore = score;
      best = parsed;
    }
  }
  return best;
}

NodeDiscoverAdvertResponse? _parseNodeDiscoverAdvertPayload(
  Uint8List payload, {
  bool allowEmptyName = false,
}) {
  if (payload.length < (allowEmptyName ? 8 : 12)) return null;
  final publicKey = payload.sublist(
    0,
    payload.length >= 8 ? 8 : payload.length,
  );
  final isAllZero = publicKey.every((b) => b == 0);
  if (isAllZero) return null;
  final publicKeyPrefix = publicKey
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  if (publicKeyPrefix.isEmpty) return null;

  final type = payload.length > 32 ? payload[32] : 0;
  final name = _extractBestAdvertName(payload);
  if (!allowEmptyName && name.isEmpty) return null;

  return NodeDiscoverAdvertResponse(
    publicKeyPrefix: publicKeyPrefix,
    name: name,
    nodeType: type,
  );
}

String _extractBestAdvertName(Uint8List payload) {
  String best = '';
  var bestScore = 0;
  const candidateOffsets = <int>[contactNameOffset - 1, 111, 107, 103, 95];
  for (final offset in candidateOffsets) {
    if (offset >= payload.length) continue;
    final candidate = readCString(
      payload,
      offset,
      (payload.length - offset).clamp(0, maxNameSize),
    ).trim();
    final score = _contactNameScore(candidate);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }

  final searchStart = payload.length > 64 ? 64 : 0;
  final searchEnd = payload.length > 4 ? payload.length - 4 : payload.length;
  for (var i = searchStart; i < searchEnd; i++) {
    final maxLen = (payload.length - i).clamp(0, maxNameSize);
    if (maxLen < 4) continue;
    final candidate = readCString(payload, i, maxLen).trim();
    final score = _contactNameScore(candidate);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return bestScore >= 8 ? best : '';
}

class TransportProtocol {
  const TransportProtocol(this.transport);

  final Transport transport;

  Future<void> run(ProtocolCommand command) => command.execute(transport);

  Stream<NodeDiscoverResponse> nodeDiscoverResponses() {
    return transport.inbound
        .map(parseNodeDiscoverResponse)
        .where((message) => message != null)
        .cast<NodeDiscoverResponse>();
  }

  Stream<NodeDiscoverAdvertResponse> nodeDiscoverAdvertResponses() {
    return transport.inbound
        .map(parseNodeDiscoverAdvertResponse)
        .where((message) => message != null)
        .cast<NodeDiscoverAdvertResponse>();
  }

  Stream<RadioContact> contactResponses() {
    return transport.inbound
        .map(parseRadioContact)
        .where((message) => message != null)
        .cast<RadioContact>();
  }

  Stream<void> endOfContactsResponses() {
    return transport.inbound.where(isEndOfContactsFrame).map((_) {});
  }
}
