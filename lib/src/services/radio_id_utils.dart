import 'dart:typed_data';

/// Strips all non-hex characters and uppercases.
String normalizeHexId(String value) {
  return value.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
}

/// Minimum hex characters needed before a prefix is treated as a radio id.
const int minHexIdMatchLength = 8;

/// Returns true when two hex IDs likely refer to the same radio.
///
/// Exact equality always matches. A prefix match is allowed only when the
/// shorter id is at least [minHexIdMatchLength] characters, so an 8-char
/// scan id matches that radio's longer public-key prefix, while a 1-byte
/// path hash cannot claim every contact that starts with the same byte.
/// Two longer keys that merely share an 8-char prefix are different radios.
bool idsLikelySameDevice(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final minLen = a.length < b.length ? a.length : b.length;
  if (minLen < minHexIdMatchLength) return false;
  return a.startsWith(b) || b.startsWith(a);
}

/// True when every hex id is the same radio: each is a prefix of the longest.
///
/// Two 16-char keys that only share an 8-char prefix are different radios,
/// so an 8-char scan id that matches both is ambiguous.
bool hexIdsAreOneRadio(Iterable<String> hexes) {
  String? longest;
  var count = 0;
  for (final hex in hexes) {
    if (hex.isEmpty) continue;
    count += 1;
    if (longest == null || hex.length > longest.length) longest = hex;
  }
  if (count <= 1 || longest == null) return true;
  for (final hex in hexes) {
    if (hex.isEmpty) continue;
    if (hex != longest && !longest.startsWith(hex)) return false;
  }
  return true;
}

/// Whether a stored name key may be applied to [query].
///
/// Full public keys match only when they are the same radio (exact equality,
/// or one is a prefix of the other, at least [minHexIdMatchLength] hex).
/// An 8-character prefix is used only when the full key is unknown, and only
/// if no other known key shares that prefix for a different radio. Shorter
/// prefixes and name-word matching are never used.
bool nameKeyAppliesTo(
  String stored,
  String query, {
  Iterable<String> allKnownKeys = const [],
}) {
  final a = normalizeHexId(stored);
  final b = normalizeHexId(query);
  if (a.isEmpty || b.isEmpty) return false;
  if (a != b && !idsLikelySameDevice(a, b)) return false;
  final shorter = a.length <= b.length ? a : b;
  if (shorter.length != minHexIdMatchLength) {
    // Exact full-key match, or two long keys with a prefix relationship.
    return a == b || idsLikelySameDevice(a, b);
  }
  // An 8-char key (or query) is only usable when every known key with that
  // prefix belongs to the same radio. Two contacts sharing the prefix make
  // the short id ambiguous, including an exact 8-char stored name.
  final related = <String>{a, b};
  for (final raw in allKnownKeys) {
    final key = normalizeHexId(raw);
    if (key.length < minHexIdMatchLength) continue;
    if (key == shorter || key.startsWith(shorter)) {
      related.add(key);
    }
  }
  return hexIdsAreOneRadio(related);
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

  // Keep apostrophes and other punctuation. Strip only control characters.
  candidate = candidate
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
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

/// Advertised/sender name eligible for upload.
///
/// Empty, unknown, and id-shaped short ids are omitted so the worker can
/// keep a historical real name. Local UI may still show [shortNodeId].
String? uploadableNodeName(String? name, String nodeId) {
  final trimmed = (name ?? '').trim();
  if (trimmed.isEmpty || isPlaceholderNodeName(trimmed, nodeId)) {
    return null;
  }
  return trimmed;
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
  // Store the exact id only. An 8-char alias of a longer public key would
  // let a different radio that shares that prefix inherit the wrong name.
  for (final key in <String>{trimmed, hex}) {
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
/// longer contact key. Returns null when more than one radio matches, so a
/// short or colliding prefix cannot show the wrong contact name.
String? resolvedNameForNodeId(Map<String, String> names, String nodeId) {
  if (names.isEmpty || nodeId.trim().isEmpty) return null;
  final target = normalizeHexId(nodeId);
  final allKeys = names.keys;
  final matchedHex = <String>[];
  final matchedName = <String>[];
  for (final entry in names.entries) {
    final rawKey = entry.key.trim();
    if (rawKey.isEmpty) continue;
    final key = normalizeHexId(rawKey);
    final same = target.isEmpty
        ? rawKey == nodeId.trim()
        : key.isNotEmpty &&
            nameKeyAppliesTo(key, target, allKnownKeys: allKeys);
    if (!same) continue;
    final name = entry.value.trim();
    if (name.isEmpty || isPlaceholderNodeName(name, nodeId)) continue;
    matchedHex.add(key.isEmpty ? rawKey : key);
    matchedName.add(name);
  }
  if (matchedName.isEmpty) return null;
  if (!hexIdsAreOneRadio(matchedHex)) return null;
  String? best;
  var bestLen = -1;
  for (var i = 0; i < matchedName.length; i++) {
    final rank = matchedHex[i].length;
    if (rank > bestLen) {
      bestLen = rank;
      best = matchedName[i];
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


/// Extra self-info attempts after the first timeout, before giving up.
const int selfInfoTimeoutRetries = 1;

/// Runs [action] and, on failure, retries up to [retries] more times.
///
/// Used for the post-connect self-info request so a single 3s timeout does
/// not skip the public key and fall back to guessing identity from contacts.
Future<T> runWithRetries<T>(
  Future<T> Function() action, {
  int retries = selfInfoTimeoutRetries,
}) async {
  Object? lastError;
  StackTrace? lastTrace;
  for (var attempt = 0; attempt <= retries; attempt++) {
    try {
      return await action();
    } catch (e, st) {
      lastError = e;
      lastTrace = st;
    }
  }
  Error.throwWithStackTrace(lastError!, lastTrace!);
}

/// Mesh identity of the radio this device is connected to.
///
/// [meshIdPrefix] comes only from a self-info public key (or that key's
/// exact pubkey/prefix). Contact name words are never a source of identity.
/// [displayName] prefers the self-info name; a contact name is never used
/// to replace it. When self-info is missing, [meshIdPrefix] is null and
/// [displayName] is the BLE advertisement name only.
class ConnectedRadioIdentity {
  const ConnectedRadioIdentity({this.meshIdPrefix, this.displayName});

  final String? meshIdPrefix;
  final String? displayName;
}

/// Resolves the connected radio's id and display name.
///
/// [contacts] may confirm an exact pubkey/prefix of [selfInfoMeshIdPrefix]
/// or [selfInfoPublicKeyHex], but are never scored by shared name words and
/// never supply a name that overrides [selfInfoDisplayName].
ConnectedRadioIdentity resolveConnectedRadioIdentity({
  String? selfInfoMeshIdPrefix,
  String? selfInfoPublicKeyHex,
  String? selfInfoDisplayName,
  String bleDeviceName = '',
  Map<String, String> contacts = const {},
}) {
  final selfName = (selfInfoDisplayName ?? '').trim();
  final prefix = normalizeHexId(selfInfoMeshIdPrefix ?? '');
  final pub = normalizeHexId(selfInfoPublicKeyHex ?? '');
  String mesh = prefix;
  if (mesh.isEmpty && pub.isNotEmpty) {
    mesh = pub.length >= 8 ? pub.substring(0, 8) : pub;
  }

  if (mesh.isEmpty) {
    // Leave identity unknown. Display the BLE name only — never a contact key.
    final ble = cleanRadioDisplayName(bleDeviceName);
    return ConnectedRadioIdentity(
      meshIdPrefix: null,
      displayName: ble.isEmpty ? null : ble,
    );
  }

  // [contacts] is accepted so callers can confirm an exact key separately
  // via exactContactNameForKey. It never contributes a name or mesh id here.
  final display = selfName.isNotEmpty
      ? selfName
      : cleanRadioDisplayName(bleDeviceName);
  return ConnectedRadioIdentity(
    meshIdPrefix: mesh,
    displayName: display.isEmpty ? null : display,
  );
}

/// Contact name whose key is this radio's public key or a prefix of it.
///
/// Returns null when no key matches, or when more than one radio could
/// match the same short id. Name-word scoring is not used.
String? exactContactNameForKey(
  Map<String, String> contacts,
  String meshId, {
  String publicKeyHex = '',
}) {
  if (contacts.isEmpty) return null;
  final mesh = normalizeHexId(meshId);
  final pub = normalizeHexId(publicKeyHex);
  if (mesh.isEmpty && pub.isEmpty) return null;
  final matches = <String, String>{};
  final allKeys = contacts.keys;
  for (final entry in contacts.entries) {
    final key = normalizeHexId(entry.key);
    if (key.isEmpty) continue;
    final name = entry.value.trim();
    if (name.isEmpty) continue;
    final same = (pub.isNotEmpty &&
            nameKeyAppliesTo(key, pub, allKnownKeys: allKeys)) ||
        (mesh.isNotEmpty &&
            nameKeyAppliesTo(key, mesh, allKnownKeys: allKeys));
    if (!same) continue;
    matches[key] = name;
  }
  if (matches.isEmpty) return null;
  if (!hexIdsAreOneRadio(matches.keys)) return null;
  String? best;
  var bestLen = -1;
  for (final entry in matches.entries) {
    if (entry.key.length > bestLen) {
      bestLen = entry.key.length;
      best = entry.value;
    }
  }
  return best;
}

