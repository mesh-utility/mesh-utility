/// One contact in the on-device master book for a radio.
///
/// Never uploaded as a whole; only REPEATER/ROOM names may ride along on
/// coverage uploads via existing gating.
class LocalContact {
  const LocalContact({
    required this.publicKeyPrefix,
    required this.name,
    required this.type,
    required this.lastHeard,
    this.lastMod,
    this.path,
    this.source = 'sync',
  });

  final String publicKeyPrefix;
  final String name;

  /// MeshCore advert/contact type: chat=1, repeater=2, room=3, sensor=4.
  final int type;
  final DateTime lastHeard;

  /// Companion-clock unix seconds (contact `lastmod`). Stays on device.
  /// `null` or `<= 0` means unknown. Resume sync uses the newest value.
  final int? lastMod;

  /// Optional path / out-path hint from discover when known.
  final String? path;

  /// `sync`, `advert`, `discover`, or `push`.
  final String source;

  LocalContact copyWith({
    String? publicKeyPrefix,
    String? name,
    int? type,
    DateTime? lastHeard,
    int? lastMod,
    String? path,
    String? source,
  }) {
    return LocalContact(
      publicKeyPrefix: publicKeyPrefix ?? this.publicKeyPrefix,
      name: name ?? this.name,
      type: type ?? this.type,
      lastHeard: lastHeard ?? this.lastHeard,
      lastMod: lastMod ?? this.lastMod,
      path: path ?? this.path,
      source: source ?? this.source,
    );
  }

  Map<String, dynamic> toJson() => {
    'publicKeyPrefix': publicKeyPrefix,
    'name': name,
    'type': type,
    'lastHeard': lastHeard.toUtc().toIso8601String(),
    'lastMod': lastMod,
    'path': path,
    'source': source,
  };

  factory LocalContact.fromJson(Map<String, dynamic> json) {
    return LocalContact(
      publicKeyPrefix: (json['publicKeyPrefix'] ?? '').toString().toUpperCase(),
      name: (json['name'] ?? '').toString(),
      type: (json['type'] as num?)?.toInt() ?? 0,
      lastHeard:
          DateTime.tryParse(json['lastHeard']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      lastMod: (json['lastMod'] as num?)?.toInt(),
      path: json['path']?.toString(),
      source: (json['source'] ?? 'sync').toString(),
    );
  }
}

/// Newest positive companion `lastmod` in [contacts], or null when none.
int? newestStoredLastMod(Iterable<LocalContact> contacts) {
  int? newest;
  for (final contact in contacts) {
    final value = contact.lastMod;
    if (value == null || value <= 0) continue;
    if (newest == null || value > newest) newest = value;
  }
  return newest;
}

/// Case-insensitive substring match on name or public-key prefix.
List<LocalContact> filterLocalContacts(
  Iterable<LocalContact> contacts,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return List<LocalContact>.from(contacts);
  return contacts
      .where(
        (c) =>
            c.name.toLowerCase().contains(q) ||
            c.publicKeyPrefix.toLowerCase().contains(q),
      )
      .toList(growable: false);
}

/// Prefer non-empty names; keep the newer lastHeard; preserve path when set.
LocalContact mergeLocalContact(LocalContact existing, LocalContact incoming) {
  final name = incoming.name.trim().isNotEmpty
      ? incoming.name.trim()
      : existing.name;
  final lastHeard = incoming.lastHeard.isAfter(existing.lastHeard)
      ? incoming.lastHeard
      : existing.lastHeard;
  final type = incoming.type != 0 ? incoming.type : existing.type;
  final path = (incoming.path != null && incoming.path!.trim().isNotEmpty)
      ? incoming.path
      : existing.path;
  final lastMod = _newerLastMod(existing.lastMod, incoming.lastMod);
  return LocalContact(
    publicKeyPrefix: existing.publicKeyPrefix,
    name: name,
    type: type,
    lastHeard: lastHeard,
    lastMod: lastMod,
    path: path,
    source: incoming.source,
  );
}

int? _newerLastMod(int? existing, int? incoming) {
  final a = (existing != null && existing > 0) ? existing : null;
  final b = (incoming != null && incoming > 0) ? incoming : null;
  if (a == null) return b;
  if (b == null) return a;
  return a > b ? a : b;
}
