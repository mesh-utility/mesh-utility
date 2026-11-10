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
/// not walk the history again. Matching uses the full public key when it is
/// known, and an exact 8-char prefix only when the full key is unknown and
/// no other stored key shares that prefix for a different radio.
class FirstAdvertisedNameIndex {
  final Map<String, List<_HexName>> _by8 = <String, List<_HexName>>{};
  final List<_HexName> _shorts = <_HexName>[];
  final Map<String, String> _raw = <String, String>{};
  final Set<String> _seen = <String>{};
  final Set<String> _allHex = <String>{};
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
    _allHex.add(hex);
    if (hex.length >= 8) {
      _by8
          .putIfAbsent(hex.substring(0, 8), () => <_HexName>[])
          .add(_HexName(hex, name, _seq++));
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
    final matches = <_HexName>[];
    void consider(_HexName candidate) {
      if (!nameKeyAppliesTo(candidate.hex, target, allKnownKeys: _allHex)) {
        return;
      }
      matches.add(candidate);
    }

    if (target.length >= 8) {
      final bucket = _by8[target.substring(0, 8)];
      if (bucket != null) {
        for (final candidate in bucket) {
          consider(candidate);
        }
      }
    } else {
      for (final bucket in _by8.values) {
        for (final candidate in bucket) {
          consider(candidate);
        }
      }
    }
    for (final candidate in _shorts) {
      consider(candidate);
    }
    if (matches.isEmpty) return null;
    if (!hexIdsAreOneRadio(matches.map((m) => m.hex))) return null;
    matches.sort((a, b) => a.order.compareTo(b.order));
    return matches.first.name;
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
    final allKeys = _allKeys();
    _visit(upper, (entry) {
      if (!nameKeyAppliesTo(entry.hex, upper, allKnownKeys: allKeys)) {
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

  Iterable<String> _allKeys() sync* {
    for (final bucket in _by8.values) {
      for (final entry in bucket) {
        yield entry.hex;
      }
    }
    for (final entry in _shorts) {
      yield entry.hex;
    }
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
    final allKeys = <String>[
      for (final bucket in _by8.values) for (final e in bucket) e.hex,
      for (final e in _shorts) e.hex,
    ];
    void consider(_HexType entry) {
      if (!nameKeyAppliesTo(entry.hex, upper, allKnownKeys: allKeys)) {
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
