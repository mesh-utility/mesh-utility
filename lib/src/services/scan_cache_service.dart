import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/services/boundary_catalog.dart';
import 'package:mesh_utility/src/services/off_ui.dart';
import 'package:mesh_utility/src/services/scan_cache_area.dart';
import 'package:mesh_utility/src/services/settings_store.dart';

/// Prunes downloaded scans for the active cache area off the UI isolate.
///
/// Hex membership is remembered for the current area signature so scans that
/// share a cell, including across later prunes, do not repeat the test.
class ScanCacheService {
  ScanCacheService({BoundaryCatalog? catalog})
    : _catalog = catalog ?? BoundaryCatalog();

  final BoundaryCatalog _catalog;
  final Map<String, bool> _hexMembership = <String, bool>{};
  String _signature = '';

  Future<List<RawScan>> prune({
    required List<RawScan> scans,
    required AppSettings settings,
    double? centerLat,
    double? centerLng,
    DateTime? now,
  }) async {
    final mode = clampScanCacheMode(settings.scanCacheMode);
    if (!scanCacheWillFilter(
      mode: mode,
      centerLat: centerLat,
      centerLng: centerLng,
    )) {
      return scans;
    }
    final signature = scanCacheMembershipSignature(
      mode: mode,
      radiusMiles: settings.scanCacheRadiusMiles,
      centerLat: centerLat,
      centerLng: centerLng,
      admin1Ids: settings.scanCacheAdmin1Ids,
      admin2Ids: settings.scanCacheAdmin2Ids,
    );
    if (signature != _signature) {
      _signature = signature;
      _hexMembership.clear();
    }
    final selected = _selectedIds(mode, settings);
    final geometry = await _geometry(mode: mode, selected: selected);
    final result = await runOffUi(pruneScanCacheWorker, <String, Object?>{
      'scans': scans,
      'mode': mode,
      'radiusMiles': settings.scanCacheRadiusMiles,
      'centerLat': centerLat,
      'centerLng': centerLng,
      'selectedIds': selected,
      'geometry': geometry,
      'membership': Map<String, bool>.from(_hexMembership),
    }, force: true);
    _hexMembership
      ..clear()
      ..addAll(result.hexMembership);
    return result.scans;
  }

  /// Union bbox of the selected divisions. Null when the selection is empty
  /// or the outlines could not be loaded.
  Future<DivisionBbox?> bboxFor({
    required bool counties,
    required List<String> selectedIds,
  }) async {
    if (selectedIds.isEmpty) return null;
    final geometry = await _catalog.geometryFor(
      counties: counties,
      selectedIds: selectedIds,
    );
    if (geometry.isEmpty) return null;
    final raw = await runOffUi(bboxFromGeometryWorker, <String, Object?>{
      'selectedIds': selectedIds,
      'geometry': geometry,
    }, force: true);
    if (raw == null) return null;
    return DivisionBbox(
      minLatitude: raw['minLat'] ?? double.nan,
      minLongitude: raw['minLng'] ?? double.nan,
      maxLatitude: raw['maxLat'] ?? double.nan,
      maxLongitude: raw['maxLng'] ?? double.nan,
    );
  }

  /// True when [latitude]/[longitude] is inside the selected admin outlines.
  /// An empty selection is outside.
  Future<bool> containsDivisionPoint({
    required bool counties,
    required List<String> selectedIds,
    required double latitude,
    required double longitude,
  }) async {
    if (selectedIds.isEmpty) return false;
    final geometry = await _catalog.geometryFor(
      counties: counties,
      selectedIds: selectedIds,
    );
    if (geometry.isEmpty) return false;
    return runOffUi(pointInsideGeometryWorker, <String, Object?>{
      'selectedIds': selectedIds,
      'geometry': geometry,
      'lat': latitude,
      'lng': longitude,
    }, force: true);
  }


  List<String> _selectedIds(String mode, AppSettings settings) {
    if (mode == scanCacheModeAdmin1) return settings.scanCacheAdmin1Ids;
    if (mode == scanCacheModeAdmin2) return settings.scanCacheAdmin2Ids;
    return const <String>[];
  }

  Future<List<Map<String, String>>> _geometry({
    required String mode,
    required List<String> selected,
  }) async {
    if (mode == scanCacheModeRadius || selected.isEmpty) {
      return const <Map<String, String>>[];
    }
    return _catalog.geometryFor(
      counties: mode == scanCacheModeAdmin2,
      selectedIds: selected,
    );
  }

}
