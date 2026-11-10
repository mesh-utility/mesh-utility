import 'package:flutter/services.dart';
import 'package:mesh_utility/src/services/off_ui.dart';
import 'package:mesh_utility/src/services/scan_cache_area.dart';

class BoundaryCountry {
  const BoundaryCountry({required this.code, required this.name});

  final String code;
  final String name;
}

/// Mid-level row. US states in the county index. Empty for admin-1.
class BoundaryRegion {
  const BoundaryRegion({
    required this.code,
    required this.name,
    required this.countryCode,
  });

  final String code;
  final String name;
  final String countryCode;
}

class BoundaryDivision {
  const BoundaryDivision({
    required this.id,
    required this.countryCode,
    required this.name,
    this.parentName = '',
  });

  final String id;
  final String countryCode;
  final String name;
  final String parentName;
}

class BoundaryIndex {
  const BoundaryIndex({
    required this.source,
    required this.countries,
    required this.divisions,
    this.regions = const <BoundaryRegion>[],
  });

  final String source;
  final List<BoundaryCountry> countries;
  final List<BoundaryDivision> divisions;

  /// States under [countries]. Present for the US county index only.
  final List<BoundaryRegion> regions;

  static const empty = BoundaryIndex(
    source: '',
    countries: <BoundaryCountry>[],
    divisions: <BoundaryDivision>[],
  );
}

/// Loads simplified boundary indexes and per-country geometry files.
///
/// Indexes are decoded off the UI isolate. Geometry text is loaded only for
/// the countries or states the caller asks for.
class BoundaryCatalog {
  BoundaryCatalog({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  final Map<String, String> _geometry = <String, String>{};
  BoundaryIndex? _admin1;
  BoundaryIndex? _admin2;
  Future<BoundaryIndex>? _admin1Loading;
  Future<BoundaryIndex>? _admin2Loading;

  Future<BoundaryIndex> loadAdmin1Index() {
    final cached = _admin1;
    if (cached != null) return Future<BoundaryIndex>.value(cached);
    return _admin1Loading ??= _loadIndex(
      'assets/boundaries/admin1/index.json',
      (index) => _admin1 = index,
    );
  }

  Future<BoundaryIndex> loadAdmin2Index() {
    final cached = _admin2;
    if (cached != null) return Future<BoundaryIndex>.value(cached);
    return _admin2Loading ??= _loadIndex(
      'assets/boundaries/admin2/us/index.json',
      (index) => _admin2 = index,
    );
  }

  Future<BoundaryIndex> _loadIndex(
    String path,
    void Function(BoundaryIndex index) store,
  ) async {
    try {
      final raw = await _bundle.loadString(path);
      final decoded = await runOffUi(
        parseBoundaryIndexWorker,
        raw,
        force: true,
      );
      final index = boundaryIndexFromDecoded(decoded);
      store(index);
      return index;
    } catch (_) {
      const empty = BoundaryIndex.empty;
      store(empty);
      return empty;
    }
  }

  Future<List<Map<String, String>>> geometryFor({
    required bool counties,
    required Iterable<String> selectedIds,
  }) async {
    final grouped = groupScanCacheIds(selectedIds);
    final payload = <Map<String, String>>[];
    final safeCode = RegExp(r'^[A-Za-z0-9]{2,3}$');
    for (final entry in grouped.entries) {
      if (!safeCode.hasMatch(entry.key)) continue;
      final path = counties
          ? 'assets/boundaries/admin2/us/states/${entry.key}.json'
          : 'assets/boundaries/admin1/countries/${entry.key}.json';
      final cached = _geometry[path];
      if (cached != null) {
        payload.add(<String, String>{'country': entry.key, 'json': cached});
        continue;
      }
      try {
        final text = await _bundle.loadString(path);
        _geometry[path] = text;
        payload.add(<String, String>{'country': entry.key, 'json': text});
      } catch (_) {
        // A missing chunk drops membership for that division only.
      }
    }
    return payload;
  }
}

BoundaryIndex boundaryIndexFromDecoded(Object? decoded) {
  if (decoded is! Map) return BoundaryIndex.empty;
  final source = decoded['source']?.toString() ?? '';
  final countryNames = <String, String>{};
  final countries = <BoundaryCountry>[];
  final countryRaw = decoded['countries'];
  if (countryRaw is List) {
    for (final row in countryRaw) {
      if (row is! Map) continue;
      final code = row['c']?.toString() ?? '';
      final name = row['n']?.toString() ?? code;
      if (code.isEmpty) continue;
      countryNames[code] = name;
      countries.add(BoundaryCountry(code: code, name: name));
    }
  }
  final stateNames = <String, String>{};
  final regions = <BoundaryRegion>[];
  final stateRaw = decoded['states'];
  // Keep the country (United States). States used to replace countries, which
  // made the county picker treat each state as a top-level country.
  final regionCountry = countries.length == 1 ? countries.first.code : '';
  if (stateRaw is List && stateRaw.isNotEmpty) {
    for (final row in stateRaw) {
      if (row is! Map) continue;
      final code = row['c']?.toString() ?? '';
      final name = row['n']?.toString() ?? code;
      if (code.isEmpty) continue;
      stateNames[code] = name;
      regions.add(
        BoundaryRegion(code: code, name: name, countryCode: regionCountry),
      );
    }
  }
  final divisions = <BoundaryDivision>[];
  final divisionRaw = decoded['divisions'];
  if (divisionRaw is List) {
    for (final row in divisionRaw) {
      if (row is! Map) continue;
      final id = row['i']?.toString() ?? '';
      if (id.isEmpty) continue;
      final countryCode = row['c']?.toString() ?? '';
      final parent = row['s']?.toString() ?? stateNames[countryCode] ?? '';
      divisions.add(
        BoundaryDivision(
          id: id,
          countryCode: countryCode,
          name: row['n']?.toString() ?? id,
          parentName: parent.isNotEmpty
              ? parent
              : (countryNames[countryCode] ?? countryCode),
        ),
      );
    }
  }
  return BoundaryIndex(
    source: source,
    countries: List<BoundaryCountry>.unmodifiable(countries),
    regions: List<BoundaryRegion>.unmodifiable(regions),
    divisions: List<BoundaryDivision>.unmodifiable(divisions),
  );
}
