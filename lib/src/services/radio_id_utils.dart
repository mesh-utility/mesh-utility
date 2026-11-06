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
  return value.split(RegExp(r'[^a-z0-9]+')).where((t) => t.length >= 3).toSet();
}

/// Short public-key prefix used when a node has no real name.
///
/// Empty input becomes "Unknown". Non-hex text is returned trimmed. Hex ids
/// are uppercased and cut to 8 characters.
String shortNodeId(String nodeId) {
  final hex = normalizeHexId(nodeId);
  if (hex.isEmpty) {
    final raw = nodeId.trim();
    return raw.isEmpty ? 'Unknown' : raw;
  }
  return hex.length >= 8 ? hex.substring(0, 8) : hex;
}

/// Local UI title for a mesh node.
///
/// Prefers [contactName] for every contact type, then a non-placeholder
/// [advertisedName] (node name or scan sender). The short id is used only
/// when neither is a real name. Do not use this for upload names; repeater
/// and room gating stays on the scan-sender path.
String titleNameForNode({
  required String nodeId,
  String? contactName,
  String? advertisedName,
}) {
  final contact = (contactName ?? '').trim();
  if (contact.isNotEmpty && !isPlaceholderNodeName(contact, nodeId)) {
    return contact;
  }
  final advertised = (advertisedName ?? '').trim();
  if (advertised.isNotEmpty && !isPlaceholderNodeName(advertised, nodeId)) {
    return advertised;
  }
  return shortNodeId(nodeId);
}

/// Stores [label] for [id] only when it is a real name.
///
/// ID-shaped placeholders are omitted so [resolvedNameForNodeId] is not
/// polluted by the short-id fallback. Keys are the raw id, its hex form, and
/// the 8-character prefix.
void putResolvedNodeLabel(
  Map<String, String> labels,
  String? id,
  String label,
) {
  final trimmed = (id ?? '').trim();
  if (trimmed.isEmpty) return;
  final cleaned = label.trim();
  if (cleaned.isEmpty || isPlaceholderNodeName(cleaned, trimmed)) return;
  final hex = normalizeHexId(trimmed);
  final short = hex.length >= 8 ? hex.substring(0, 8) : hex;
  for (final key in <String>{trimmed, hex, short}) {
    if (key.isEmpty) continue;
    final existing = labels[key];
    if (existing != null &&
        !isPlaceholderNodeName(existing, key) &&
        isPlaceholderNodeName(cleaned, key)) {
      continue;
    }
    labels[key] = cleaned;
  }
}

/// Best human label from a resolved-name map.
///
/// Skips ID-shaped placeholders and, when several keys match the same radio,
/// prefers the longest public-key prefix so a short ID entry cannot hide a
/// longer contact key.
String? resolvedNameForNodeId(Map<String, String> names, String nodeId) {
  if (names.isEmpty || nodeId.trim().isEmpty) return null;
  final target = normalizeHexId(nodeId);
  String? best;
  var bestLen = -1;
  for (final entry in names.entries) {
    final rawKey = entry.key.trim();
    if (rawKey.isEmpty) continue;
    final key = normalizeHexId(rawKey);
    final same = target.isEmpty
        ? rawKey == nodeId.trim()
        : key.isNotEmpty && (key == target || idsLikelySameDevice(key, target));
    if (!same) continue;
    final name = entry.value.trim();
    if (name.isEmpty || isPlaceholderNodeName(name, nodeId)) continue;
    final rank = key.isEmpty ? rawKey.length : key.length;
    if (rank > bestLen) {
      bestLen = rank;
      best = name;
    }
  }
  return best;
}

/// Whether [name] looks like an auto-generated placeholder ("Unknown" or this
/// node's own hex id) rather than a human name.
///
/// The label is ID-shaped only when the whole string is hex (optional
/// separators) and at least 8 digits, and that id refers to [nodeId]. Human
/// names that merely contain hex letters stay names. Stripping those letters
/// and prefix-matching the residue treated names like "TestAbe" as the id
/// whenever the node id started with the leftover hex.
bool isPlaceholderNodeName(String name, String nodeId) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return true;
  final lower = trimmed.toLowerCase();
  if (lower == 'unknown' ||
      (lower.startsWith('unknown (') && lower.endsWith(')'))) {
    return true;
  }
  if (!_isHexIdShapedLabel(trimmed)) return false;
  final nameHex = normalizeHexId(trimmed);
  final nodeHex = normalizeHexId(nodeId);
  return nameHex.isNotEmpty &&
      nodeHex.isNotEmpty &&
      idsLikelySameDevice(nameHex, nodeHex);
}

/// True when [value] is only a hex id, not a word that happens to use A-F.
bool _isHexIdShapedLabel(String value) {
  final compact = value.replaceAll(RegExp(r'[\s:\-_]'), '');
  if (compact.length < 8) return false;
  return RegExp(r'^[0-9A-Fa-f]+$').hasMatch(compact);
}
