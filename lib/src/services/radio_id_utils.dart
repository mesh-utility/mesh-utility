import 'dart:typed_data';

/// Strips all non-hex characters and uppercases.
String normalizeHexId(String value) {
  return value.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
}

/// Returns true when two hex IDs likely refer to the same device (either one
/// is a prefix/suffix of the other, or they share the first 8 characters).
bool idsLikelySameDevice(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  if (a.startsWith(b) || b.startsWith(a)) return true;
  final a8 = a.length >= 8 ? a.substring(0, 8) : a;
  final b8 = b.length >= 8 ? b.substring(0, 8) : b;
  return a8 == b8;
}

/// Returns a normalised 8-char mesh radio ID, or null when [value] looks like
/// a BLE MAC address or is otherwise unsafe.
String? safePublicRadioId(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return null;
  if (raw.contains(':') || raw.contains('-')) return null;
  final normalized = normalizeHexId(raw);
  if (normalized.isEmpty) return null;
  // Avoid leaking BLE MAC-like IDs.
  if (normalized.length == 12) return null;
  return normalized.length >= 8 ? normalized.substring(0, 8) : normalized;
}

/// Removes noise tokens (e.g. "ble") and collapses extra whitespace from a
/// radio display name.
String cleanRadioDisplayName(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return value;
  value = value.replaceAll(RegExp(r'\bble\b', caseSensitive: false), '').trim();
  value = value.replaceAll(RegExp(r'\s{2,}'), ' ');
  if (value == '-' || value == '_' || value == '()') return '';
  return value;
}

/// Hex-encodes [bytes] in uppercase.
String bytesToHex(Uint8List bytes) {
  return bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

/// Extracts printable ASCII characters (0x20–0x7E) from a byte list.
String extractPrintableAscii(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    if (b >= 32 && b <= 126) sb.writeCharCode(b);
  }
  return sb.toString();
}

/// Attempts to pull a human-readable radio name from a MeshCore self-info
/// text blob (everything after the last `$` marker).
String? extractSelfInfoDisplayName(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  var candidate = trimmed;
  final markerIndex = candidate.lastIndexOf(r'$');
  if (markerIndex >= 0 && markerIndex + 1 < candidate.length) {
    candidate = candidate.substring(markerIndex + 1);
  }
  candidate = candidate.trim();
  if (candidate.isEmpty) return null;

  candidate = candidate
      .replaceAll(RegExp(r'[^A-Za-z0-9 ._\-]'), '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  candidate = cleanRadioDisplayName(candidate);
  if (candidate.length < 3) return null;
  return candidate;
}

/// Splits [value] into lowercase tokens of at least 3 characters.
Set<String> nameTokens(String value) {
  return value
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.length >= 3)
      .toSet();
}

/// Whether [name] looks like an auto-generated placeholder ("Unknown", hex ID,
/// etc.) for [nodeId].
bool isPlaceholderNodeName(String name, String nodeId) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return true;
  final lower = trimmed.toLowerCase();
  if (lower == 'unknown' ||
      (lower.startsWith('unknown (') && lower.endsWith(')'))) {
    return true;
  }
  final nameHex = normalizeHexId(trimmed);
  final nodeHex = normalizeHexId(nodeId);
  return nameHex.isNotEmpty &&
      nodeHex.isNotEmpty &&
      idsLikelySameDevice(nameHex, nodeHex);
}
