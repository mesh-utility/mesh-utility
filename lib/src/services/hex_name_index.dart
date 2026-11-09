import 'package:mesh_utility/src/services/radio_id_utils.dart';

class _HexName {
  const _HexName(this.hex, this.name, this.order);

  final String hex;
  final String name;
  final int order;
}

/// First usable advertised name for a radio id.
///
/// Walks nodes, then scan results, then raw scans once. A later lookup does
/// not walk the history again. Matching follows [idsLikelySameDevice]: the
/// earliest usable name in an 8-char prefix group wins, including a short id
/// that appears before a longer one. Queries shorter than 8 hex characters
/// only match an exact stored id, so a path hash cannot copy a name from
/// another cell.
class FirstAdvertisedNameIndex {
  final Map<String, _HexName> _by8 = <String, _HexName>{};
  final List<_HexName> _shorts = <_HexName>[];
  final Map<String, String> _raw = <String, String>{};
  final Set<String> _seen = <String>{};
  var _seq = 0;

  void add(String rawId, String? rawName) {
    final name = _usableAdvertisedName(rawName, rawId);
    if (name == null) return;
    final hex = normalizeHexId(rawId);
    if (hex.isEmpty) {
      final raw = rawId.trim();
      if (raw.isEmpty) return;
      _raw.putIfAbsent(raw, () => name);
      return;
    }
    if (!_seen.add(hex)) return;
    if (hex.length >= 8) {
      final key = hex.substring(0, 8);
      // Bucket identity is the 8-char scan id, so two longer prefixes of the
      // same radio share one advertised name. Contact uniqueness lives in
      // LongestHexNameIndex.
      final candidate = _HexName(key, name, _seq++);
      final existing = _by8[key];
      if (existing == null || candidate.order < existing.order) {
        _by8[key] = candidate;
      }
      return;
    }
    _shorts.add(_HexName(hex, name, _seq++));
  }

  String? lookup(String rawId) {
    final target = normalizeHexId(rawId);
    if (target.isEmpty) {
      final raw = rawId.trim();
      if (raw.isEmpty) return null;
      return _raw[raw];
    }
    _HexName? best;
    void consider(_HexName? candidate) {
      if (candidate == null) return;
      if (candidate.hex != target &&
          !idsLikelySameDevice(candidate.hex, target)) {
        return;
      }
      if (best == null || candidate.order < best!.order) best = candidate;
    }

    if (target.length >= 8) {
      consider(_by8[target.substring(0, 8)]);
    } else {
      for (final candidate in _by8.values) {
        consider(candidate);
      }
    }
    for (final candidate in _shorts) {
      consider(candidate);
    }
    return best?.name;
  }
}

/// Longest contact-key match for [idsLikelySameDevice].
///
/// Placeholder checks use the query id, matching the contact-name loop that
/// used to walk the whole book for every scan.
class LongestHexNameIndex {
  LongestHexNameIndex.fromMap(Map<String, String> names) {
    for (final entry in names.entries) {
      add(entry.key, entry.value);
    }
  }

  final Map<String, List<_HexName>> _by8 = <String, List<_HexName>>{};
  final List<_HexName> _shorts = <_HexName>[];

  void add(String rawKey, String rawName) {
    final name = rawName.trim();
    if (name.isEmpty) return;
    final hex = normalizeHexId(rawKey);
    if (hex.isEmpty) return;
    final entry = _HexName(hex, name, 0);
    if (hex.length >= 8) {
      _by8.putIfAbsent(hex.substring(0, 8), () => <_HexName>[]).add(entry);
      return;
    }
    _shorts.add(entry);
  }

  String? lookup(String rawId) {
    final upper = normalizeHexId(rawId);
    if (upper.isEmpty) return null;
    final matches = <_HexName>[];
    _visit(upper, (entry) {
      if (entry.hex != upper && !idsLikelySameDevice(entry.hex, upper)) {
        return;
      }
      if (isPlaceholderNodeName(entry.name, upper)) return;
      matches.add(entry);
    });
    if (matches.isEmpty) return null;
    if (!hexIdsAreOneRadio(matches.map((m) => m.hex))) return null;
    String? best;
    var bestLength = -1;
    for (final entry in matches) {
      if (entry.hex.length > bestLength) {
        bestLength = entry.hex.length;
        best = entry.name;
      }
    }
    return best;
  }

  /// True when any stored key refers to the same radio, even if its name is
  /// a placeholder. Used only for the backfill match counter.
  bool matchesId(String rawId) {
    final upper = normalizeHexId(rawId);
    if (upper.isEmpty) return false;
    var found = false;
    _visit(upper, (entry) {
      if (entry.hex == upper || idsLikelySameDevice(entry.hex, upper)) {
        found = true;
      }
    });
    return found;
  }

  void _visit(String upper, void Function(_HexName entry) consider) {
    if (upper.length >= 8) {
      final bucket = _by8[upper.substring(0, 8)];
      if (bucket != null) {
        for (final entry in bucket) {
          consider(entry);
        }
      }
    } else {
      for (final bucket in _by8.values) {
        for (final entry in bucket) {
          consider(entry);
        }
      }
    }
    for (final entry in _shorts) {
      consider(entry);
    }
  }
}

/// Longest contact-key match for an integer contact type.
class LongestHexTypeIndex {
  LongestHexTypeIndex(Map<String, int> types) {
    for (final entry in types.entries) {
      final hex = normalizeHexId(entry.key);
      if (hex.isEmpty) continue;
      final stored = _HexType(hex, entry.value);
      if (hex.length >= 8) {
        _by8.putIfAbsent(hex.substring(0, 8), () => <_HexType>[]).add(stored);
      } else {
        _shorts.add(stored);
      }
    }
  }

  final Map<String, List<_HexType>> _by8 = <String, List<_HexType>>{};
  final List<_HexType> _shorts = <_HexType>[];

  int? lookup(String rawId) {
    final upper = normalizeHexId(rawId);
    if (upper.isEmpty) return null;
    final matches = <_HexType>[];
    void consider(_HexType entry) {
      if (entry.hex != upper && !idsLikelySameDevice(entry.hex, upper)) {
        return;
      }
      matches.add(entry);
    }

    if (upper.length >= 8) {
      final bucket = _by8[upper.substring(0, 8)];
      if (bucket != null) {
        for (final entry in bucket) {
          consider(entry);
        }
      }
    } else {
      for (final bucket in _by8.values) {
        for (final entry in bucket) {
          consider(entry);
        }
      }
    }
    for (final entry in _shorts) {
      consider(entry);
    }
    if (matches.isEmpty) return null;
    if (!hexIdsAreOneRadio(matches.map((m) => m.hex))) return null;
    int? best;
    var bestLength = -1;
    for (final entry in matches) {
      if (entry.hex.length > bestLength) {
        bestLength = entry.hex.length;
        best = entry.type;
      }
    }
    return best;
  }
}

class _HexType {
  const _HexType(this.hex, this.type);

  final String hex;
  final int type;
}

String? _usableAdvertisedName(String? name, String id) {
  final trimmed = (name ?? '').trim();
  if (trimmed.isEmpty || isPlaceholderNodeName(trimmed, id)) return null;
  return trimmed;
}
