import 'dart:typed_data';

import 'package:mesh_utility/transport/protocol.dart';

/// Reassembles MeshCore BLE notification chunks into complete frames.
///
/// Contact frames (148 bytes) often span multiple notifications. Push/advert
/// frames can arrive interleaved; those must not be appended into a partial
/// contact buffer or the stream desyncs.
class BleFrameAssembler {
  BleFrameAssembler({this.onWarn});

  final void Function(String message)? onWarn;

  final List<int> _buffer = <int>[];
  int? _code;
  int? _expectedLength;
  bool _contactStripChunkHeader = false;

  void clear() {
    _buffer.clear();
    _code = null;
    _expectedLength = null;
    _contactStripChunkHeader = false;
  }

  /// Feed one BLE notification payload. Returns zero or more complete frames.
  List<Uint8List> push(Uint8List bytes) {
    if (bytes.isEmpty) return const [];
    final out = <Uint8List>[];
    _append(bytes, out);
    return out;
  }

  void _append(Uint8List bytes, List<Uint8List> out) {
    if (_code != null &&
        _canFlushPartialOnBoundary(_code!, _buffer, bytes)) {
      out.add(Uint8List.fromList(_buffer));
      clear();
    }

    // Mid-contact: a new frame-start (PUSH/control/end/start) must not be
    // appended into the contact buffer.
    if (_code == respCodeContact &&
        _buffer.isNotEmpty &&
        _isForeignFrameStart(bytes)) {
      onWarn?.call(
        'Dropping incomplete contact frame '
        '(${_buffer.length}/$contactFrameSize bytes) due to interleaved '
        'frame code=0x${bytes[0].toRadixString(16)}',
      );
      clear();
    }

    if (_code == null) {
      final code = bytes[0];
      if (!_isChunkProneCode(code)) {
        out.add(bytes);
        return;
      }
      _code = code;
      _buffer.clear();
      _contactStripChunkHeader = false;
      if (code == respCodeContact) {
        _appendContactChunk(bytes);
      } else {
        _buffer.addAll(bytes);
      }
    } else {
      if (_code == respCodeContact) {
        _appendContactChunk(bytes);
      } else {
        _buffer.addAll(bytes);
      }
    }

    _expectedLength = _expectedLengthForCode(_code!, _buffer);

    if (_expectedLength == null) {
      if (_buffer.length > maxFrameSize * 3) {
        onWarn?.call(
          'Dropping oversized partial frame code=$_code bytes=${_buffer.length}',
        );
        clear();
      }
      return;
    }

    final expected = _expectedLength!;
    if (_buffer.length < expected) return;

    out.add(Uint8List.fromList(_buffer.sublist(0, expected)));

    if (_buffer.length == expected) {
      clear();
      return;
    }

    final trailing = Uint8List.fromList(_buffer.sublist(expected));
    clear();
    _append(trailing, out);
  }

  bool _isForeignFrameStart(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final code = bytes[0];
    // Continuation notifications may repeat the contact code as a 1-byte
    // header; those are handled by _appendContactChunk, not as foreign.
    if (code == respCodeContact) return false;
    // Do NOT treat respCodeOk (0x00) as interleaved — contact payloads often
    // contain zero bytes at chunk boundaries. Only codes that start real
    // standalone BLE notifications interrupt contact assembly.
    return code == respCodeContactsStart ||
        code == respCodeEndOfContacts ||
        code == respCodeErr ||
        code == respCodeSelfInfo ||
        code == respCodeDeviceInfo ||
        code == pushCodeControlData ||
        code == pushCodeAdvert ||
        code == pushCodeNewAdvert ||
        code == pushCodeAdvertCompact;
  }

  bool _isChunkProneCode(int code) {
    return code == respCodeContact ||
        code == pushCodeControlData ||
        code == pushCodeNewAdvert ||
        code == pushCodeAdvert;
  }

  int? _expectedLengthForCode(int code, List<int> bytes) {
    if (code == respCodeContact) return contactFrameSize;
    if (code == pushCodeControlData) {
      if (bytes.length < 4) return null;
      final declaredLen = bytes[3];
      if (declaredLen == 0 && bytes.length > 4) {
        return bytes.length;
      }
      return 4 + declaredLen;
    }
    if (code == pushCodeNewAdvert || code == pushCodeAdvert) {
      if (bytes.length < 4) return null;
      return 4 + bytes[3];
    }
    return null;
  }

  bool _canFlushPartialOnBoundary(
    int code,
    List<int> current,
    Uint8List incoming,
  ) {
    if (incoming.isEmpty) return false;
    if (code != respCodeSelfInfo && code != respCodeDeviceInfo) return false;
    if (current.length < 20) return false;
    return _looksLikeFrameStart(incoming[0]);
  }

  bool _looksLikeFrameStart(int code) {
    return code == respCodeOk ||
        code == respCodeErr ||
        code == respCodeContactsStart ||
        code == respCodeContact ||
        code == respCodeEndOfContacts ||
        code == respCodeSelfInfo ||
        code == respCodeDeviceInfo ||
        code == pushCodeControlData ||
        code == pushCodeAdvert ||
        code == pushCodeNewAdvert;
  }

  void _appendContactChunk(Uint8List bytes) {
    if (_buffer.isEmpty) {
      _buffer.addAll(bytes);
      return;
    }
    if (!_contactStripChunkHeader &&
        bytes.length > 1 &&
        bytes[0] == respCodeContact) {
      _contactStripChunkHeader = true;
    }
    if (_contactStripChunkHeader && bytes.length > 1) {
      _buffer.addAll(bytes.sublist(1));
      return;
    }
    _buffer.addAll(bytes);
  }
}
