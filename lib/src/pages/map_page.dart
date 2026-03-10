import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/signal_class.dart';
import 'package:mesh_utility/src/services/tile_cache_service.dart';
import 'package:mesh_utility/src/widgets/map_page_widgets.dart';
import 'package:mesh_utility/src/widgets/map_top_controls.dart';
import 'dart:math';

enum BaseLayer { dark, standard, satellite }

class MapPage extends StatefulWidget {
  const MapPage({
    super.key,
    required this.zones,
    required this.onRefresh,
    required this.syncing,
    required this.forceOffline,
    required this.bleConnected,
    required this.bleBusy,
    required this.bleStatus,
    required this.bleScanning,
    required this.bleScanStatus,
    required this.bleDiscoveries,
    required this.bleNextScanCountdown,
    required this.bleLastDiscoverAt,
    required this.bleLastDiscoverCount,
    required this.bleLastDiscoverError,
    required this.autoCenter,
    required this.onToggleAutoCenter,
    required this.onBleConnect,
    required this.onBleDisconnect,
    required this.onBleNodeDiscover,
    required this.onBleToggleScan,
    required this.onOpenHistoryFromZone,
    this.focusHexId,
    this.focusNodeId,
    this.resolvedNodeNames = const {},
    required this.scans,
    required this.rawScans,
    required this.nodesCount,
    required this.statsRadiusMiles,
    required this.unitSystem,
    required this.tileCachingEnabled,
    required this.bleUiEnabled,
    this.observerLat,
    this.observerLng,
    this.connectedRadioName,
    this.connectedRadioMeshId,
  });

  final List<CoverageZone> zones;
  final Future<void> Function() onRefresh;
  final bool syncing;
  final bool forceOffline;

  final bool bleConnected;
  final bool bleBusy;
  final String bleStatus;
  final bool bleScanning;
  final String bleScanStatus;
  final int bleDiscoveries;
  final int? bleNextScanCountdown;
  final DateTime? bleLastDiscoverAt;
  final int bleLastDiscoverCount;
  final String? bleLastDiscoverError;

  final bool autoCenter;
  final Future<void> Function(bool value) onToggleAutoCenter;

  final Future<void> Function() onBleConnect;
  final Future<void> Function() onBleDisconnect;
  final Future<void> Function() onBleNodeDiscover;
  final Future<void> Function() onBleToggleScan;
  final ValueChanged<String> onOpenHistoryFromZone;
  final String? focusHexId;
  final String? focusNodeId;
  final Map<String, String> resolvedNodeNames;
  final List<ScanResult> scans;
  final List<RawScan> rawScans;
  final int nodesCount;
  final int statsRadiusMiles;
  final String unitSystem;
  final bool tileCachingEnabled;
  final bool bleUiEnabled;
  final double? observerLat;
  final double? observerLng;
  final String? connectedRadioName;
  final String? connectedRadioMeshId;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  final AppDebugLogService _debugLog = AppDebugLogService.instance;
  BaseLayer _baseLayer = BaseLayer.standard;
  Brightness? _lastThemeBrightness;
  bool _layerSelectorExpanded = false;
  bool _legendExpanded = false;
  final LayerHitNotifier<String> _polygonHitNotifier = ValueNotifier(null);
  double _mapViewportHeight = 700;
  CoverageZone? _selectedZone;
  String? _lastNodeFilterDebugSignature;
  String? _lastPopupDebugSignature;
  LatLng? _lastAutoCenterTarget;
  DateTime? _lastAutoCenterDisableAt;
  Set<String> _selectedNodeFilters = <String>{};
  late TileProvider _tileProvider;

  @override
  void initState() {
    super.initState();
    _tileProvider = TileCacheService.createTileProvider(
      enabled: widget.tileCachingEnabled,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusHexIfRequested();
      _maybeAutoCenterOnObserver();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_lastThemeBrightness == brightness) return;
    _lastThemeBrightness = brightness;
    _baseLayer = _defaultBaseLayerForBrightness(brightness);
  }

  @override
  void didUpdateWidget(covariant MapPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tileCachingEnabled != oldWidget.tileCachingEnabled) {
      _tileProvider = TileCacheService.createTileProvider(
        enabled: widget.tileCachingEnabled,
      );
    }
    if (widget.autoCenter) {
      final observerMoved =
          widget.observerLat != oldWidget.observerLat ||
          widget.observerLng != oldWidget.observerLng;
      final autoCenterEnabledNow = !oldWidget.autoCenter && widget.autoCenter;
      if (observerMoved || autoCenterEnabledNow) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _maybeAutoCenterOnObserver(),
        );
      }
    }
    if (widget.focusHexId != oldWidget.focusHexId ||
        widget.focusNodeId != oldWidget.focusNodeId ||
        widget.zones != oldWidget.zones) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focusHexIfRequested(),
      );
    }
  }

  @override
  void dispose() {
    _tileProvider.dispose();
    _polygonHitNotifier.dispose();
    super.dispose();
  }

  void _handlePolygonTap() {
    final hit = _polygonHitNotifier.value;
    if (hit == null || hit.hitValues.isEmpty) {
      _debugLog.debug('ui_click', 'Map polygon tap with no hit values');
      return;
    }
    final zoneId = hit.hitValues.first;
    _debugLog.info('ui_click', 'Map hex click zone=$zoneId');
    CoverageZone? zone;
    for (final z in widget.zones) {
      if (z.id == zoneId) {
        zone = z;
        break;
      }
    }
    if (zone != null) {
      _disableAutoCenter('popup open');
      setState(() {
        _selectedZone = zone;
        _legendExpanded = false;
        _lastPopupDebugSignature = null;
      });
      _focusZone(zone);
    }
  }

  void _disableAutoCenter(String reason) {
    if (!widget.autoCenter) return;
    final now = DateTime.now();
    if (_lastAutoCenterDisableAt != null &&
        now.difference(_lastAutoCenterDisableAt!) <
            const Duration(milliseconds: 900)) {
      return;
    }
    _lastAutoCenterDisableAt = now;
    _debugLog.info('ui_click', 'Auto-center disabled: $reason');
    unawaited(widget.onToggleAutoCenter(false));
  }

  void _focusZone(CoverageZone zone) {
    const targetZoom = 16.4;
    final pixelsDown = (_mapViewportHeight * 0.23).clamp(96.0, 190.0);
    final metersPerPixel =
        156543.03392 * cos(zone.centerLat * pi / 180.0) / pow(2.0, targetZoom);
    final metersDown = pixelsDown * metersPerPixel;
    final latOffset = metersDown / 111320.0;
    _mapController.move(
      LatLng(zone.centerLat + latOffset, zone.centerLng),
      targetZoom,
    );
  }

  void _maybeAutoCenterOnObserver() {
    if (!mounted || !widget.autoCenter) return;
    final lat = widget.observerLat;
    final lng = widget.observerLng;
    if (lat == null || lng == null) return;
    if (_selectedZone != null) return;

    final target = LatLng(lat, lng);
    if (_lastAutoCenterTarget != null) {
      final movedMiles = _distanceMiles(
        _lastAutoCenterTarget!.latitude,
        _lastAutoCenterTarget!.longitude,
        target.latitude,
        target.longitude,
      );
      // Avoid jitter from tiny GPS updates.
      if (movedMiles < 0.01) {
        return;
      }
    }
    _lastAutoCenterTarget = target;
    final zoom = _mapController.camera.zoom;
    _debugLog.debug(
      'map_auto_center',
      'Recenter to lat=${target.latitude.toStringAsFixed(6)} '
          'lng=${target.longitude.toStringAsFixed(6)} zoom=${zoom.toStringAsFixed(2)}',
    );
    _mapController.move(target, zoom);
  }

  Future<void> _handleAutoCenterToggleFromControls() async {
    _debugLog.info('ui_click', 'Map controls auto-center toggle');
    final nextValue = !widget.autoCenter;
    await widget.onToggleAutoCenter(nextValue);
    if (!mounted || !nextValue) return;

    final lat = widget.observerLat;
    final lng = widget.observerLng;
    if (lat == null || lng == null) return;

    if (_selectedZone != null) {
      setState(() {
        _selectedZone = null;
      });
    }
    final target = LatLng(lat, lng);
    _lastAutoCenterTarget = target;
    const minZoom = 15.8;
    final zoom = _mapController.camera.zoom < minZoom
        ? minZoom
        : _mapController.camera.zoom;
    _debugLog.debug(
      'map_auto_center',
      'Manual center to lat=${target.latitude.toStringAsFixed(6)} '
          'lng=${target.longitude.toStringAsFixed(6)} zoom=${zoom.toStringAsFixed(2)}',
    );
    _mapController.move(target, zoom);
  }

  void _focusHexIfRequested() {
    if (_focusNodeIfRequested()) return;
    final hexId = widget.focusHexId;
    if (hexId == null || hexId.isEmpty) return;
    CoverageZone? zone;
    for (final z in widget.zones) {
      if (z.id == hexId) {
        zone = z;
        break;
      }
    }
    if (zone == null || !mounted) return;
    setState(() {
      _selectedZone = zone;
      _legendExpanded = false;
      _lastPopupDebugSignature = null;
    });
    _focusZone(zone);
  }

  bool _focusNodeIfRequested() {
    if (_selectedNodeFilters.isNotEmpty) return false;
    final nodeId = widget.focusNodeId;
    if (nodeId == null || nodeId.isEmpty) return false;
    final nodeKey = _nodeFilterKey(nodeId);
    if (nodeKey.isEmpty) return false;
    final nodeHexes = <String>{};
    for (final scan in widget.scans) {
      if (_nodeFilterKey(scan.nodeId) == nodeKey) {
        nodeHexes.add(hexKey(scan.latitude, scan.longitude));
      }
    }
    if (nodeHexes.isEmpty) {
      debugPrint(
        '[map_filter] Node filter requested for $nodeId but found 0 scan hexes',
      );
      _debugLog.warn(
        'map_filter',
        'Node filter requested for $nodeId but found 0 scan hexes',
      );
      return false;
    }
    final nodeZones = widget.zones
        .where((z) => nodeHexes.contains(z.id))
        .toList(growable: false);
    _debugLog.info(
      'map_filter',
      'Node $nodeKey filter: scansHexes=${nodeHexes.length}, matchedZones=${nodeZones.length}, totalZones=${widget.zones.length}',
    );
    debugPrint(
      '[map_filter] Node $nodeKey filter: scansHexes=${nodeHexes.length}, '
      'matchedZones=${nodeZones.length}, totalZones=${widget.zones.length}',
    );
    final candidates = nodeZones;
    CoverageZone? target;
    for (final z in candidates) {
      if (target == null ||
          z.lastScanned.isAfter(target.lastScanned) ||
          (z.lastScanned == target.lastScanned &&
              (z.avgRssi ?? -999) > (target.avgRssi ?? -999))) {
        target = z;
      }
    }
    if (target == null || !mounted) return false;
    setState(() {
      // Node-focus mode should not auto-open a zone popup.
      _selectedZone = null;
      _legendExpanded = false;
      _lastPopupDebugSignature = null;
    });
    if (nodeZones.length <= 1) {
      _focusZone(target);
      return true;
    }

    final coordinates = <LatLng>[];
    for (final zone in nodeZones) {
      if (zone.polygon.isNotEmpty) {
        coordinates.addAll(zone.polygon);
      } else {
        coordinates.add(LatLng(zone.centerLat, zone.centerLng));
      }
    }
    if (coordinates.isEmpty) {
      _focusZone(target);
      return true;
    }

    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: coordinates,
        padding: const EdgeInsets.fromLTRB(24, 120, 56, 130),
        maxZoom: 16.2,
        minZoom: 8,
      ),
    );
    return true;
  }

  void _focusCoverageForNodeFilters(Set<String> nodeFilters) {
    if (nodeFilters.isEmpty) return;
    final nodeHexes = <String>{};
    for (final scan in widget.scans) {
      final key = _nodeFilterKey(scan.nodeId);
      if (key.isNotEmpty && nodeFilters.contains(key)) {
        nodeHexes.add(hexKey(scan.latitude, scan.longitude));
      }
    }
    if (nodeHexes.isEmpty) return;
    final nodeZones = widget.zones
        .where((z) => nodeHexes.contains(z.id))
        .toList(growable: false);
    if (nodeZones.isEmpty) return;

    final coordinates = <LatLng>[];
    for (final zone in nodeZones) {
      if (zone.polygon.isNotEmpty) {
        coordinates.addAll(zone.polygon);
      } else {
        coordinates.add(LatLng(zone.centerLat, zone.centerLng));
      }
    }
    if (coordinates.isEmpty) return;
    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: coordinates,
        padding: const EdgeInsets.fromLTRB(24, 120, 56, 130),
        maxZoom: 16.2,
        minZoom: 8,
      ),
    );
  }

  Set<String> _effectiveNodeFilters({
    required String? focusNodeId,
    required Set<String> selectedNodeFilters,
  }) {
    if (selectedNodeFilters.isNotEmpty) {
      return selectedNodeFilters;
    }
    if (focusNodeId == null || focusNodeId.isEmpty) {
      return const <String>{};
    }
    final key = _nodeFilterKey(focusNodeId);
    if (key.isEmpty) return const <String>{};
    return <String>{key};
  }

  Future<void> _openNodeFilterDialog() async {
    final options = _nodeFilterOptions(
      scans: widget.scans,
      resolvedNodeNames: widget.resolvedNodeNames,
    );
    if (!mounted) return;
    final selected = Set<String>.from(_selectedNodeFilters);
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) =>
          _NodeFilterDialog(options: options, initiallySelected: selected),
    );
    if (!mounted || result == null) return;
    final signatureBefore = _selectedNodeFilters.toList()..sort();
    final signatureAfter = result.toList()..sort();
    if (signatureBefore.join(',') == signatureAfter.join(',')) {
      return;
    }
    _debugLog.info(
      'map_filter',
      'Node filter updated: count=${result.length} ids=${signatureAfter.join(',')}',
    );
    setState(() {
      _selectedNodeFilters = result;
      if (_selectedZone != null &&
          !_zoneMatchesNodeFilter(
            zone: _selectedZone!,
            scans: widget.scans,
            nodeIdFilters: _effectiveNodeFilters(
              focusNodeId: widget.focusNodeId,
              selectedNodeFilters: _selectedNodeFilters,
            ),
          )) {
        _selectedZone = null;
        _lastPopupDebugSignature = null;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusCoverageForNodeFilters(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final center = widget.zones.isNotEmpty
        ? LatLng(widget.zones.first.centerLat, widget.zones.first.centerLng)
        : const LatLng(39.5, -98.35);

    final focusNodeId = widget.focusNodeId;
    final effectiveNodeFilters = _effectiveNodeFilters(
      focusNodeId: focusNodeId,
      selectedNodeFilters: _selectedNodeFilters,
    );
    final baseZones = effectiveNodeFilters.isEmpty
        ? widget.zones
        : () {
            final nodeHexes = <String>{};
            for (final scan in widget.scans) {
              final key = _nodeFilterKey(scan.nodeId);
              if (key.isNotEmpty && effectiveNodeFilters.contains(key)) {
                nodeHexes.add(hexKey(scan.latitude, scan.longitude));
              }
            }
            return widget.zones
                .where((zone) => nodeHexes.contains(zone.id))
                .toList(growable: false);
          }();

    final bypassRadiusForNodeFocus =
        focusNodeId != null &&
        focusNodeId.isNotEmpty &&
        _selectedNodeFilters.isEmpty &&
        effectiveNodeFilters.isNotEmpty;
    final filteredZones = bypassRadiusForNodeFocus
        ? baseZones
        : _filterZonesByRadius(
            zones: baseZones,
            observerLat: widget.observerLat,
            observerLng: widget.observerLng,
            radiusMiles: widget.statsRadiusMiles,
          );
    final filteredZoneIds = filteredZones.map((z) => z.id).toSet();
    final scopedNodeIds = <String>{};
    for (final scan in widget.scans) {
      final nodeKey = _nodeFilterKey(scan.nodeId);
      if (nodeKey.isEmpty) continue;
      if (effectiveNodeFilters.isNotEmpty &&
          !effectiveNodeFilters.contains(nodeKey)) {
        continue;
      }
      if (!filteredZoneIds.contains(hexKey(scan.latitude, scan.longitude))) {
        continue;
      }
      scopedNodeIds.add(nodeKey);
    }
    final scopedNodesCount = scopedNodeIds.length;
    if (effectiveNodeFilters.isNotEmpty) {
      final filterLabel = _selectedNodeFilters.isNotEmpty
          ? 'custom(${effectiveNodeFilters.length})'
          : focusNodeId!;
      final signature =
          '$filterLabel|zones:${widget.zones.length}|base:${baseZones.length}|filtered:${filteredZones.length}|radiusBypass:$bypassRadiusForNodeFocus';
      if (signature != _lastNodeFilterDebugSignature) {
        _lastNodeFilterDebugSignature = signature;
        debugPrint(
          '[map_filter] Render filter active for $filterLabel: '
          'base=${baseZones.length}, afterRadius=${filteredZones.length}, '
          'radiusBypass=$bypassRadiusForNodeFocus',
        );
        _debugLog.debug(
          'map_filter',
          'Render filter active for $filterLabel: base=${baseZones.length}, afterRadius=${filteredZones.length}, radiusBypass=$bypassRadiusForNodeFocus',
        );
      }
    } else {
      _lastNodeFilterDebugSignature = null;
    }
    final activeZones = filteredZones.where((z) => !z.isDeadZone).toList();
    final deadZones = filteredZones.where((z) => z.isDeadZone).toList();
    final avgRssi = activeZones.isNotEmpty
        ? activeZones.fold<double>(0, (sum, z) => sum + (z.avgRssi ?? 0)) /
              activeZones.length
        : 0.0;
    final avgSnr = activeZones.isNotEmpty
        ? activeZones.fold<double>(0, (sum, z) => sum + (z.avgSnr ?? 0)) /
              activeZones.length
        : 0.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final viewHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.of(context).size.height;
        final overlayTop = 20.0;
        _mapViewportHeight = viewHeight;
        final narrowOverlay = viewWidth < 420;
        final statsBottom = 0.0;
        final statsEstimatedHeight = 96.0;
        // Keep legend clear of bottom stats panel in both collapsed/expanded states.
        final legendBottom = statsBottom + statsEstimatedHeight + 18;
        final legendExpandedWidth = min(viewWidth - 24, 154.0);
        final legendReservedWidth = 56.0;
        final maxPopupWidth = max(120.0, viewWidth - 24);
        final popupWidth = narrowOverlay ? min(maxPopupWidth, 300.0) : 280.0;
        final popupMinTop = 116.0;
        final popupMaxTop = max(popupMinTop, viewHeight - 320.0);
        final popupTop = narrowOverlay
            ? 138.0
            : (viewHeight * 0.26).clamp(popupMinTop, popupMaxTop);
        final centeredPopupLeft = (viewWidth - popupWidth) / 2;
        final maxPopupLeftBeforeLegend =
            viewWidth - popupWidth - legendReservedWidth - 8;
        final popupLeft = max(
          12.0,
          min(centeredPopupLeft, maxPopupLeftBeforeLegend),
        );

        return Stack(
          children: [
            Positioned.fill(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: widget.zones.isNotEmpty ? 10 : 4,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all,
                  ),
                  onPositionChanged: (_, hasGesture) {
                    if (hasGesture) {
                      _disableAutoCenter('map gesture');
                    }
                  },
                  onTap: (tapPosition, latLng) {
                    _disableAutoCenter('map tap');
                    final hit = _polygonHitNotifier.value;
                    if (hit != null && hit.hitValues.isNotEmpty) {
                      _debugLog.debug(
                        'ui_click',
                        'Map tap ignored because polygon hit is active '
                            '(hits=${hit.hitValues.length})',
                      );
                      return;
                    }
                    _debugLog.debug(
                      'ui_click',
                      'Map background click clear popup at lat=${latLng.latitude.toStringAsFixed(6)} lng=${latLng.longitude.toStringAsFixed(6)}',
                    );
                    setState(() {
                      _selectedZone = null;
                      _lastPopupDebugSignature = null;
                    });
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: _layerTemplate(_baseLayer),
                    userAgentPackageName: 'mesh_utility',
                    tileProvider: _tileProvider,
                    maxZoom: 19,
                  ),
                  if (widget.observerLat != null && widget.observerLng != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: LatLng(
                            widget.observerLat!,
                            widget.observerLng!,
                          ),
                          width: 28,
                          height: 28,
                          child: const IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0x663B82F6),
                              ),
                              child: Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Color(0xFF3B82F6),
                                    border: Border.fromBorderSide(
                                      BorderSide(color: Colors.white, width: 2),
                                    ),
                                  ),
                                  child: SizedBox(width: 12, height: 12),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (filteredZones.any((z) => z.polygon.isNotEmpty))
                    MouseRegion(
                      hitTestBehavior: HitTestBehavior.deferToChild,
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _handlePolygonTap,
                        child: PolygonLayer<String>(
                          hitNotifier: _polygonHitNotifier,
                          polygons: filteredZones
                              .where((z) => z.polygon.isNotEmpty)
                              .map(
                                (z) => Polygon<String>(
                                  points: z.polygon,
                                  hitValue: z.id,
                                  color: _zoneColor(z).withValues(
                                    alpha: z.isDeadZone ? 0.15 : 0.45,
                                  ),
                                  borderColor: z.isDeadZone
                                      ? const Color(0xFFEF4444)
                                      : _zoneColor(z),
                                  borderStrokeWidth: 1,
                                  pattern: z.isDeadZone
                                      ? StrokePattern.dashed(
                                          segments: const [6, 4],
                                        )
                                      : const StrokePattern.solid(),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_legendExpanded)
              Positioned(
                right: 12,
                bottom: legendBottom,
                child: Card(
                  elevation: 1,
                  child: InkWell(
                    onTap: () {
                      _debugLog.info('ui_click', 'Legend collapse click');
                      setState(() => _legendExpanded = false);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: legendExpandedWidth,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Align(
                              alignment: Alignment.center,
                              child: Icon(Icons.chevron_right, size: 16),
                            ),
                            SizedBox(height: 4),
                            LegendRow(
                              color: Color(0xFF22C55E),
                              text: 'Excellent',
                              range: 'RSSI > -90, SNR > 10',
                            ),
                            LegendRow(
                              color: Color(0xFF4ADE80),
                              text: 'Good',
                              range: 'RSSI > -100, SNR > 0',
                            ),
                            LegendRow(
                              color: Color(0xFFFACC15),
                              text: 'Fair',
                              range: 'RSSI > -110, SNR > -7',
                            ),
                            LegendRow(
                              color: Color(0xFFF97316),
                              text: 'Marginal',
                              range: 'RSSI > -115, SNR > -13',
                            ),
                            LegendRow(
                              color: Color(0xFFEF4444),
                              text: 'Poor',
                              range: 'Weak signal',
                            ),
                            LegendRow(
                              color: Color(0xFF991B1B),
                              text: 'Dead Zone',
                              range: 'No response',
                            ),
                            LegendRow(
                              color: Color(0xFFA855F7),
                              text: 'Noisy',
                              range: 'Good signal, bad SNR',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              Positioned(
                right: 12,
                bottom: legendBottom,
                child: Card(
                  elevation: 1,
                  child: InkWell(
                    onTap: () {
                      _debugLog.info('ui_click', 'Legend expand click');
                      setState(() => _legendExpanded = true);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            LegendSwatch(color: Color(0xFF22C55E)),
                            SizedBox(height: 4),
                            LegendSwatch(color: Color(0xFF4ADE80)),
                            SizedBox(height: 4),
                            LegendSwatch(color: Color(0xFFFACC15)),
                            SizedBox(height: 4),
                            LegendSwatch(color: Color(0xFFF97316)),
                            SizedBox(height: 4),
                            LegendSwatch(color: Color(0xFFEF4444)),
                            SizedBox(height: 4),
                            LegendSwatch(color: Color(0xFF991B1B)),
                            SizedBox(height: 4),
                            LegendSwatch(color: Color(0xFFA855F7)),
                            SizedBox(height: 6),
                            Icon(Icons.chevron_left, size: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: overlayTop,
              right: 12,
              child: Row(
                children: [
                  Card(
                    elevation: 1,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            _debugLog.info(
                              'ui_click',
                              'Map filter button click',
                            );
                            _openNodeFilterDialog();
                          },
                          icon: const Icon(Icons.filter_alt),
                          tooltip: 'Filter by nodes',
                        ),
                        if (_selectedNodeFilters.isNotEmpty)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Card(
                    elevation: 1,
                    child: _layerSelectorExpanded
                        ? Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 4,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    setState(() {
                                      _baseLayer = BaseLayer.dark;
                                      _layerSelectorExpanded = false;
                                    });
                                  },
                                  icon: Icon(
                                    Icons.dark_mode,
                                    color: _baseLayer == BaseLayer.dark
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                  tooltip: 'Dark map',
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    setState(() {
                                      _baseLayer = BaseLayer.standard;
                                      _layerSelectorExpanded = false;
                                    });
                                  },
                                  icon: Icon(
                                    Icons.public,
                                    color: _baseLayer == BaseLayer.standard
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                  tooltip: 'Standard map',
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    setState(() {
                                      _baseLayer = BaseLayer.satellite;
                                      _layerSelectorExpanded = false;
                                    });
                                  },
                                  icon: Icon(
                                    Icons.satellite_alt,
                                    color: _baseLayer == BaseLayer.satellite
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                  tooltip: 'Satellite map',
                                ),
                              ],
                            ),
                          )
                        : IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              setState(() => _layerSelectorExpanded = true);
                            },
                            icon: Icon(switch (_baseLayer) {
                              BaseLayer.dark => Icons.dark_mode,
                              BaseLayer.standard => Icons.public,
                              BaseLayer.satellite => Icons.satellite_alt,
                            }),
                            tooltip: 'Map layers',
                          ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: overlayTop,
              left: 12,
              child: MapTopControls(
                autoCenter: widget.autoCenter,
                onToggleAutoCenter: () =>
                    unawaited(_handleAutoCenterToggleFromControls()),
                bleConnected: widget.bleConnected,
                bleBusy: widget.bleBusy,
                bleScanning: widget.bleScanning,
                bleUiEnabled: widget.bleUiEnabled,
                onToggleScan: () {
                  _debugLog.info('ui_click', 'Map controls scan toggle click');
                  widget.onBleToggleScan();
                },
                onForceScan: () {
                  _debugLog.info('ui_click', 'Map controls force scan click');
                  widget.onBleNodeDiscover();
                },
                syncing: widget.syncing,
                forceOffline: widget.forceOffline,
                connectionLabel: widget.bleConnected
                    ? ((widget.connectedRadioName ?? '').trim().isEmpty
                          ? 'Connected'
                          : widget.connectedRadioName!.trim())
                    : 'Disconnected',
                onSync: () {
                  _debugLog.info('ui_click', 'Map controls sync click');
                  widget.onRefresh();
                },
              ),
            ),
            Positioned(
              left: 12,
              bottom: statsBottom,
              child: Builder(
                builder: (context) {
                  final screenWidth = MediaQuery.of(context).size.width;
                  final statsWidth = screenWidth < 520
                      ? screenWidth - 24
                      : 420.0;
                  return SizedBox(
                    width: statsWidth,
                    child: ScanStatsPanel(
                      nodesCount: scopedNodesCount,
                      isConnected: widget.bleConnected,
                      activeZones: activeZones.length,
                      deadZones: deadZones.length,
                      avgRssi: avgRssi,
                      avgSnr: avgSnr,
                      statsRadiusMiles: widget.statsRadiusMiles,
                      unitSystem: widget.unitSystem,
                      hasObserver:
                          widget.observerLat != null &&
                          widget.observerLng != null,
                    ),
                  );
                },
              ),
            ),
            if (_selectedZone != null)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _debugLog.info('ui_click', 'Popup scrim click close popup');
                    setState(() {
                      _selectedZone = null;
                      _lastPopupDebugSignature = null;
                    });
                  },
                  child: Container(color: Colors.black.withValues(alpha: 0.42)),
                ),
              ),
            if (_selectedZone != null)
              Positioned(
                left: popupLeft,
                top: popupTop,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: popupWidth),
                  child: Builder(
                    builder: (context) {
                      final latest = _latestScanForZone(
                        _selectedZone!,
                        widget.scans,
                        nodeIdFilters: effectiveNodeFilters,
                      );
                      final latestRaw = latest == null
                          ? _latestRawScanForZone(
                              _selectedZone!,
                              widget.rawScans,
                              nodeIdFilters: effectiveNodeFilters,
                            )
                          : null;
                      final hasSuccessfulScan =
                          latest != null && latest.rssi.isFinite;
                      final hasSuccessfulRaw =
                          latestRaw != null &&
                          (latestRaw.rssi?.isFinite ?? false);
                      final hasSuccessfulData =
                          hasSuccessfulScan || hasSuccessfulRaw;
                      final effectiveDead =
                          _selectedZone!.isDeadZone && !hasSuccessfulData;
                      final showCoverageTitle = !effectiveDead;
                      final signalClass =
                          _selectedZone!.avgRssi == null &&
                              _selectedZone!.avgSnr == null
                          ? null
                          : signalClassForValues(
                              rssi: _selectedZone!.avgRssi,
                              snr: _selectedZone!.avgSnr,
                            );
                      final popupSig = latest != null
                          ? 'zone=${_selectedZone!.id}|ts=${latest.timestamp.toIso8601String()}|node=${latest.nodeId}|obs=${_observerDisplayName(latest, connectedRadioName: widget.connectedRadioName, connectedRadioMeshId: widget.connectedRadioMeshId, resolvedNodeNames: widget.resolvedNodeNames)}|rssi=${latest.rssi.toStringAsFixed(1)}|snrOut=${latest.snr?.toStringAsFixed(1) ?? 'N/A'}|snrIn=${latest.snrIn?.toStringAsFixed(1) ?? 'N/A'}|alt=${latest.altitude?.toStringAsFixed(1) ?? 'N/A'}|scans=${_selectedZone!.scanCount}|dead=$effectiveDead'
                          : (latestRaw != null
                                ? 'zone=${_selectedZone!.id}|raw-fallback|ts=${latestRaw.effectiveTimestamp.toIso8601String()}|node=${latestRaw.nodeId ?? ''}|obs=${_observerDisplayNameRaw(latestRaw, connectedRadioName: widget.connectedRadioName, connectedRadioMeshId: widget.connectedRadioMeshId, resolvedNodeNames: widget.resolvedNodeNames)}|rssi=${latestRaw.rssi?.toStringAsFixed(1) ?? 'N/A'}|snrOut=${latestRaw.snr?.toStringAsFixed(1) ?? 'N/A'}|snrIn=${latestRaw.snrIn?.toStringAsFixed(1) ?? 'N/A'}|alt=${latestRaw.altitude?.toStringAsFixed(1) ?? 'N/A'}|scans=${_selectedZone!.scanCount}|dead=$effectiveDead'
                                : 'zone=${_selectedZone!.id}|no-scan|scans=${_selectedZone!.scanCount}|dead=$effectiveDead');
                      if (popupSig != _lastPopupDebugSignature) {
                        _lastPopupDebugSignature = popupSig;
                        _debugLog.info('popup', popupSig);
                        if (latest == null &&
                            latestRaw == null &&
                            _selectedZone!.scanCount > 0) {
                          _debugLog.warn(
                            'popup',
                            'zone=${_selectedZone!.id} has scanCount=${_selectedZone!.scanCount} but no matching scan result or raw scan',
                          );
                        }
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    showCoverageTitle
                                        ? 'Coverage Zone'
                                        : 'Dead Zone',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  if (latest == null && latestRaw == null)
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text('Last Scan: unavailable'),
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.location_on,
                                              size: 14,
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                _selectedZone!.id,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    )
                                  else if (latest == null && latestRaw != null)
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Last Scan: ${DateFormat.yMd().add_jm().format(latestRaw.effectiveTimestamp.toLocal())}',
                                        ),
                                        Row(
                                          children: [
                                            const Icon(Icons.radio, size: 14),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: OverflowMarqueeText(
                                                text: _stripPopupEntityLabel(
                                                  _observerDisplayNameRaw(
                                                    latestRaw,
                                                    connectedRadioName: widget
                                                        .connectedRadioName,
                                                    connectedRadioMeshId: widget
                                                        .connectedRadioMeshId,
                                                    resolvedNodeNames: widget
                                                        .resolvedNodeNames,
                                                    allowObserverIdentity:
                                                        showCoverageTitle,
                                                  ),
                                                ),
                                                pixelsPerSecond: 38,
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodyMedium,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            SizedBox(
                                              width: 74,
                                              child: Align(
                                                alignment:
                                                    Alignment.centerRight,
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment:
                                                      Alignment.centerRight,
                                                  child: Text(
                                                    'SNR ${latestRaw.snrIn?.toStringAsFixed(1) ?? 'N/A'} dB',
                                                    textAlign: TextAlign.right,
                                                    maxLines: 1,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const Divider(
                                          height: 8,
                                          thickness: 0.6,
                                        ),
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.settings_input_antenna,
                                              size: 14,
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                _stripPopupEntityLabel(
                                                  _nodeDisplayName(
                                                    latestRaw.senderName,
                                                    latestRaw.nodeId ??
                                                        latestRaw.observerId ??
                                                        '',
                                                    widget
                                                        .resolvedNodeNames[latestRaw
                                                            .nodeId ??
                                                        ''],
                                                  ),
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            SizedBox(
                                              width: 118,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  FittedBox(
                                                    fit: BoxFit.scaleDown,
                                                    alignment:
                                                        Alignment.centerRight,
                                                    child: Text(
                                                      'SNR ${latestRaw.snr?.toStringAsFixed(1) ?? 'N/A'} dB',
                                                      textAlign:
                                                          TextAlign.right,
                                                      maxLines: 1,
                                                    ),
                                                  ),
                                                  FittedBox(
                                                    fit: BoxFit.scaleDown,
                                                    alignment:
                                                        Alignment.centerRight,
                                                    child: Text(
                                                      'RSSI ${latestRaw.rssi?.toStringAsFixed(1) ?? 'N/A'} dBm',
                                                      textAlign:
                                                          TextAlign.right,
                                                      maxLines: 1,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        const Divider(
                                          height: 8,
                                          thickness: 0.6,
                                        ),
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.location_on,
                                              size: 14,
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                _selectedZone!.id,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (showCoverageTitle)
                                          const Divider(
                                            height: 8,
                                            thickness: 0.6,
                                          ),
                                        if (showCoverageTitle)
                                          Text(
                                            'Scans: ${_selectedZone!.scanCount}',
                                          ),
                                      ],
                                    )
                                  else ...[
                                    Text(
                                      'Last Scan: ${DateFormat.yMd().add_jm().format(latest!.timestamp.toLocal())}',
                                    ),
                                    Row(
                                      children: [
                                        const Icon(Icons.radio, size: 14),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: OverflowMarqueeText(
                                            text: _stripPopupEntityLabel(
                                              _observerDisplayName(
                                                latest,
                                                connectedRadioName:
                                                    widget.connectedRadioName,
                                                connectedRadioMeshId:
                                                    widget.connectedRadioMeshId,
                                                resolvedNodeNames:
                                                    widget.resolvedNodeNames,
                                                allowObserverIdentity:
                                                    showCoverageTitle,
                                              ),
                                            ),
                                            pixelsPerSecond: 38,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 74,
                                          child: Align(
                                            alignment: Alignment.centerRight,
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerRight,
                                              child: Text(
                                                'SNR ${latest.snrIn?.toStringAsFixed(1) ?? 'N/A'} dB',
                                                textAlign: TextAlign.right,
                                                maxLines: 1,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const Divider(height: 8, thickness: 0.6),
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.settings_input_antenna,
                                          size: 14,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: OverflowMarqueeText(
                                            text: _stripPopupEntityLabel(
                                              _nodeDisplayName(
                                                latest.senderName,
                                                latest.nodeId,
                                                widget.resolvedNodeNames[latest
                                                    .nodeId],
                                              ),
                                            ),
                                            pixelsPerSecond: 26,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 118,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            children: [
                                              FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Text(
                                                  'SNR ${latest.snr?.toStringAsFixed(1) ?? 'N/A'} dB',
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                ),
                                              ),
                                              FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Text(
                                                  'RSSI ${latest.rssi.toStringAsFixed(1)} dBm',
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const Divider(height: 8, thickness: 0.6),
                                    Row(
                                      children: [
                                        const Icon(Icons.terrain, size: 14),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            _formatAltitude(
                                              latest.altitude,
                                              widget.unitSystem,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const Divider(height: 8, thickness: 0.6),
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.hexagon_outlined,
                                          size: 14,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (signalClass != null)
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 2,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          999,
                                                        ),
                                                    gradient:
                                                        const LinearGradient(
                                                          begin: Alignment
                                                              .topCenter,
                                                          end: Alignment
                                                              .bottomCenter,
                                                          colors: [
                                                            Color(0xFF1B2329),
                                                            Color(0xFF0A0E12),
                                                          ],
                                                        ),
                                                    border: Border.all(
                                                      color: Colors.white24,
                                                      width: 0.6,
                                                    ),
                                                    boxShadow: const [
                                                      BoxShadow(
                                                        color: Colors.black54,
                                                        blurRadius: 5,
                                                        offset: Offset(0, 1),
                                                      ),
                                                    ],
                                                  ),
                                                  child: Text(
                                                    signalClass.label,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color:
                                                              signalClass.color,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 118,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            children: [
                                              FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Text(
                                                  'SNR avg ${_selectedZone!.avgSnr?.toStringAsFixed(1) ?? 'N/A'} dB',
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                ),
                                              ),
                                              FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Text(
                                                  'RSSI avg ${_selectedZone!.avgRssi?.toStringAsFixed(1) ?? 'N/A'} dBm',
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const Divider(height: 8, thickness: 0.6),
                                    Row(
                                      children: [
                                        const Icon(Icons.location_on, size: 14),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            _selectedZone!.id,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (showCoverageTitle)
                                      const Divider(height: 8, thickness: 0.6),
                                    if (showCoverageTitle)
                                      Text(
                                        'Scans: ${_selectedZone!.scanCount}',
                                      ),
                                  ],
                                  const SizedBox(height: 6),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        _debugLog.info(
                                          'ui_click',
                                          'Popup view history click zone=${_selectedZone!.id}',
                                        );
                                        widget.onOpenHistoryFromZone(
                                          _selectedZone!.id,
                                        );
                                      },
                                      icon: const Icon(Icons.history, size: 14),
                                      label: const Text('View History'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.center,
                            child: CustomPaint(
                              size: const Size(22, 10),
                              painter: PopupVPointerPainter(),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _NodeFilterOption {
  const _NodeFilterOption({
    required this.nodeId,
    required this.label,
    required this.count,
  });

  final String nodeId;
  final String label;
  final int count;
}

List<_NodeFilterOption> _nodeFilterOptions({
  required List<ScanResult> scans,
  required Map<String, String> resolvedNodeNames,
}) {
  final counts = <String, int>{};
  final labels = <String, String>{};
  for (final scan in scans) {
    final key = _nodeFilterKey(scan.nodeId);
    if (key.isEmpty) continue;
    counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    final sender = (scan.senderName ?? '').trim();
    final resolved = _bestResolvedNameForNode(
      nodeId: scan.nodeId,
      resolvedNodeNames: resolvedNodeNames,
    );
    final preferred = resolved.isNotEmpty ? resolved : sender;
    if (preferred.isNotEmpty && !preferred.startsWith('Unknown (')) {
      labels.putIfAbsent(key, () => preferred);
    }
  }
  final options = <_NodeFilterOption>[];
  for (final entry in counts.entries) {
    final label = labels[entry.key] ?? entry.key;
    options.add(
      _NodeFilterOption(nodeId: entry.key, label: label, count: entry.value),
    );
  }
  options.sort((a, b) {
    final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    if (byLabel != 0) return byLabel;
    return a.nodeId.compareTo(b.nodeId);
  });
  return options;
}

bool _zoneMatchesNodeFilter({
  required CoverageZone zone,
  required List<ScanResult> scans,
  required Set<String> nodeIdFilters,
}) {
  if (nodeIdFilters.isEmpty) return true;
  for (final scan in scans) {
    final key = _nodeFilterKey(scan.nodeId);
    if (key.isEmpty || !nodeIdFilters.contains(key)) continue;
    if (hexKey(scan.latitude, scan.longitude) == zone.id) {
      return true;
    }
  }
  return false;
}

class _NodeFilterDialog extends StatefulWidget {
  const _NodeFilterDialog({
    required this.options,
    required this.initiallySelected,
  });

  final List<_NodeFilterOption> options;
  final Set<String> initiallySelected;

  @override
  State<_NodeFilterDialog> createState() => _NodeFilterDialogState();
}

class _NodeFilterDialogState extends State<_NodeFilterDialog> {
  late final TextEditingController _searchController;
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _selected = Set<String>.from(widget.initiallySelected);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = widget.options
        .where((option) {
          if (query.isEmpty) return true;
          return option.label.toLowerCase().contains(query) ||
              option.nodeId.toLowerCase().contains(query);
        })
        .toList(growable: false);
    final ordered = [...filtered]
      ..sort((a, b) {
        final aSelected = _selected.contains(a.nodeId);
        final bSelected = _selected.contains(b.nodeId);
        if (aSelected != bSelected) {
          return aSelected ? -1 : 1;
        }
        final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
        if (byLabel != 0) return byLabel;
        return a.nodeId.compareTo(b.nodeId);
      });

    return AlertDialog(
      title: const Text('Filter Nodes'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Search node name or ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: () => setState(() => _selected.clear()),
                  child: const Text('Clear'),
                ),
                TextButton(
                  onPressed: ordered.isEmpty
                      ? null
                      : () => setState(() {
                          _selected.addAll(ordered.map((e) => e.nodeId));
                        }),
                  child: const Text('Select all shown'),
                ),
                Text('${_selected.length} selected'),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 320,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: ordered.length,
                itemBuilder: (context, index) {
                  final option = ordered[index];
                  final checked = _selected.contains(option.nodeId);
                  return CheckboxListTile(
                    value: checked,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${option.nodeId} (${option.count})'),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selected.add(option.nodeId);
                        } else {
                          _selected.remove(option.nodeId);
                        }
                      });
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

ScanResult? _latestScanForZone(
  CoverageZone zone,
  List<ScanResult> scans, {
  Set<String> nodeIdFilters = const <String>{},
}) {
  final zoneIdCenter = _parseHexKey(zone.id);
  ScanResult? latest;
  for (final scan in scans) {
    if (nodeIdFilters.isNotEmpty) {
      final key = _nodeFilterKey(scan.nodeId);
      if (key.isEmpty || !nodeIdFilters.contains(key)) continue;
    }
    bool matches = false;
    final scanHex = hexKey(scan.latitude, scan.longitude);
    if (zone.id == scanHex) {
      matches = true;
    } else {
      final snapped = snapToHexGrid(scan.latitude, scan.longitude);
      if (zoneIdCenter != null) {
        final zoneIdLat = zoneIdCenter.$1;
        final zoneIdLng = zoneIdCenter.$2;
        final bySnappedCenter =
            (snapped.snapLat - zoneIdLat).abs() < 1e-6 &&
            (snapped.snapLng - zoneIdLng).abs() < 1e-6;
        if (bySnappedCenter) {
          matches = true;
        }
      }
    }
    if (!matches) continue;
    if (latest == null || scan.timestamp.isAfter(latest.timestamp)) {
      latest = scan;
    }
  }
  return latest;
}

RawScan? _latestRawScanForZone(
  CoverageZone zone,
  List<RawScan> scans, {
  Set<String> nodeIdFilters = const <String>{},
}) {
  final zoneIdCenter = _parseHexKey(zone.id);
  RawScan? latest;
  for (final scan in scans) {
    if (nodeIdFilters.isNotEmpty) {
      final node = _nodeFilterKey(scan.nodeId ?? '');
      final observer = _nodeFilterKey(scan.observerId ?? '');
      if (!nodeIdFilters.contains(node) && !nodeIdFilters.contains(observer)) {
        continue;
      }
    }
    bool matches = false;
    final scanHex = hexKey(scan.latitude, scan.longitude);
    if (zone.id == scanHex) {
      matches = true;
    } else {
      final snapped = snapToHexGrid(scan.latitude, scan.longitude);
      if (zoneIdCenter != null) {
        final zoneIdLat = zoneIdCenter.$1;
        final zoneIdLng = zoneIdCenter.$2;
        final bySnappedCenter =
            (snapped.snapLat - zoneIdLat).abs() < 1e-6 &&
            (snapped.snapLng - zoneIdLng).abs() < 1e-6;
        if (bySnappedCenter) {
          matches = true;
        }
      }
    }
    if (!matches) continue;
    if (latest == null ||
        scan.effectiveTimestamp.isAfter(latest.effectiveTimestamp)) {
      latest = scan;
    }
  }
  return latest;
}

(double, double)? _parseHexKey(String value) {
  final parts = value.split(':');
  if (parts.length != 2) return null;
  final lat = double.tryParse(parts[0]);
  final lng = double.tryParse(parts[1]);
  if (lat == null || lng == null) return null;
  return (lat, lng);
}

String _nodeDisplayName(
  String? senderName,
  String nodeId,
  String? resolvedName,
) {
  if (senderName == null || senderName.trim().isEmpty) {
    if (resolvedName != null && resolvedName.trim().isNotEmpty) {
      return resolvedName.trim();
    }
    return nodeId;
  }
  final trimmed = senderName.trim();
  if (trimmed == nodeId &&
      resolvedName != null &&
      resolvedName.trim().isNotEmpty) {
    return resolvedName.trim();
  }
  if (trimmed.toLowerCase() == 'unknown' &&
      resolvedName != null &&
      resolvedName.trim().isNotEmpty) {
    return resolvedName.trim();
  }
  if (trimmed == 'Unknown ($nodeId)') return nodeId;
  if (trimmed.startsWith('Unknown (') && trimmed.endsWith(')')) {
    if (resolvedName != null && resolvedName.trim().isNotEmpty) {
      return resolvedName.trim();
    }
    return nodeId;
  }
  return trimmed;
}

String _observerDisplayName(
  ScanResult scan, {
  String? connectedRadioName,
  String? connectedRadioMeshId,
  Map<String, String> resolvedNodeNames = const {},
  bool allowObserverIdentity = true,
}) {
  if (!allowObserverIdentity) {
    return 'hidden';
  }
  final preferredName = connectedRadioName?.trim();
  final preferredMesh = _nodeFilterKey(connectedRadioMeshId ?? '');
  if (preferredName != null && preferredName.isNotEmpty) {
    final radioNorm = (scan.radioId ?? '').trim();
    final radioKey = _nodeFilterKey(radioNorm);
    final matchesPreferred =
        preferredMesh.isNotEmpty &&
        radioKey.isNotEmpty &&
        radioKey == preferredMesh;
    if (matchesPreferred) {
      return preferredName;
    }
  }
  final receiver = scan.receiverName?.trim();
  if (receiver != null && receiver.isNotEmpty) {
    if (_looksLikeObserverId(receiver)) {
      final receiverResolved = _bestResolvedNameForNode(
        nodeId: receiver,
        resolvedNodeNames: resolvedNodeNames,
      );
      if (receiverResolved.isNotEmpty) return receiverResolved;
    }
    return _formatObserverDisplay(receiver);
  }
  final radioId = scan.radioId?.trim();
  if (radioId != null && radioId.isNotEmpty) {
    final resolved = _bestResolvedNameForNode(
      nodeId: radioId,
      resolvedNodeNames: resolvedNodeNames,
    );
    if (resolved.isNotEmpty) return resolved;
    return _formatObserverDisplay(radioId);
  }
  final observerId = scan.observerId.trim();
  if (observerId.isNotEmpty) {
    final resolved = _bestResolvedNameForNode(
      nodeId: observerId,
      resolvedNodeNames: resolvedNodeNames,
    );
    if (resolved.isNotEmpty) return resolved;
    return _formatObserverDisplay(observerId);
  }
  return 'unknown';
}

String _observerDisplayNameRaw(
  RawScan scan, {
  String? connectedRadioName,
  String? connectedRadioMeshId,
  Map<String, String> resolvedNodeNames = const {},
  bool allowObserverIdentity = true,
}) {
  if (!allowObserverIdentity) {
    return 'hidden';
  }
  final preferredName = connectedRadioName?.trim();
  final preferredMesh = _nodeFilterKey(connectedRadioMeshId ?? '');
  if (preferredName != null && preferredName.isNotEmpty) {
    final radioNorm = (scan.radioId ?? '').trim();
    final radioKey = _nodeFilterKey(radioNorm);
    final matchesPreferred =
        preferredMesh.isNotEmpty &&
        radioKey.isNotEmpty &&
        radioKey == preferredMesh;
    if (matchesPreferred) {
      return preferredName;
    }
  }

  final receiver = scan.receiverName?.trim();
  if (receiver != null && receiver.isNotEmpty) {
    if (_looksLikeObserverId(receiver)) {
      final receiverResolved = _bestResolvedNameForNode(
        nodeId: receiver,
        resolvedNodeNames: resolvedNodeNames,
      );
      if (receiverResolved.isNotEmpty) return receiverResolved;
    }
    return _formatObserverDisplay(receiver);
  }
  final radioId = scan.radioId?.trim();
  if (radioId != null && radioId.isNotEmpty) {
    final resolved = _bestResolvedNameForNode(
      nodeId: radioId,
      resolvedNodeNames: resolvedNodeNames,
    );
    if (resolved.isNotEmpty) return resolved;
    return _formatObserverDisplay(radioId);
  }
  final observerId = scan.observerId?.trim();
  if (observerId != null && observerId.isNotEmpty) {
    final resolved = _bestResolvedNameForNode(
      nodeId: observerId,
      resolvedNodeNames: resolvedNodeNames,
    );
    if (resolved.isNotEmpty) return resolved;
    return _formatObserverDisplay(observerId);
  }
  return 'unknown';
}

String _normalizeHexId(String value) {
  return value.trim().toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
}

String _formatObserverDisplay(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return trimmed;
  final hex = _normalizeHexId(trimmed);
  if (hex.length >= 8) {
    final looksLikeId =
        trimmed.contains(':') ||
        RegExp(r'^[0-9A-F]{8,}$').hasMatch(trimmed.toUpperCase()) ||
        hex.length == trimmed.length;
    if (looksLikeId) return hex.substring(0, 8);
  }
  return trimmed;
}

bool _looksLikeObserverId(String value) {
  final normalized = value.trim().toUpperCase();
  if (normalized.isEmpty) return false;
  if (normalized.contains(':')) return true;
  final hexOnly = normalized.replaceAll(RegExp(r'[^0-9A-F]'), '');
  return hexOnly.length == 8 || hexOnly.length == 12 || hexOnly.length == 16;
}

String _nodeFilterKey(String value) {
  final hex = _normalizeHexId(value);
  if (hex.length >= 8) return hex.substring(0, 8);
  if (hex.isNotEmpty) return hex;
  final raw = value.trim().toUpperCase();
  if (raw.isEmpty) return '';
  return raw.length > 8 ? raw.substring(0, 8) : raw;
}

String _bestResolvedNameForNode({
  required String nodeId,
  required Map<String, String> resolvedNodeNames,
}) {
  final exact = (resolvedNodeNames[nodeId] ?? '').trim();
  if (exact.isNotEmpty) return exact;
  final key = _nodeFilterKey(nodeId);
  if (key.isEmpty) return '';
  for (final entry in resolvedNodeNames.entries) {
    if (_nodeFilterKey(entry.key) == key) {
      final name = entry.value.trim();
      if (name.isNotEmpty) return name;
    }
  }
  return '';
}

String _formatAltitude(double? altitudeMeters, String unitSystem) {
  if (altitudeMeters == null || !altitudeMeters.isFinite) {
    return '--';
  }
  if (unitSystem == 'metric') {
    return '${altitudeMeters.toStringAsFixed(0)} m';
  }
  final feet = altitudeMeters * 3.28084;
  return '${feet.toStringAsFixed(0)} ft';
}

String _stripPopupEntityLabel(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return trimmed;
  var candidate = trimmed
      .replaceFirst(RegExp(r'^[^A-Za-z0-9]+'), '')
      .trimLeft();
  final lower = candidate.toLowerCase();
  if (lower.startsWith('observer:')) {
    return candidate.substring('observer:'.length).trimLeft();
  }
  if (lower.startsWith('node:')) {
    return candidate.substring('node:'.length).trimLeft();
  }
  return trimmed;
}

String _layerTemplate(BaseLayer layer) {
  switch (layer) {
    case BaseLayer.dark:
      return 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
    case BaseLayer.standard:
      return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    case BaseLayer.satellite:
      return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  }
}

BaseLayer _defaultBaseLayerForBrightness(Brightness brightness) {
  return brightness == Brightness.dark ? BaseLayer.dark : BaseLayer.standard;
}

Color _zoneColor(CoverageZone zone) {
  return signalColorForValues(rssi: zone.avgRssi, snr: zone.avgSnr);
}

List<CoverageZone> _filterZonesByRadius({
  required List<CoverageZone> zones,
  required double? observerLat,
  required double? observerLng,
  required int radiusMiles,
}) {
  if (radiusMiles == 0 || observerLat == null || observerLng == null) {
    return zones;
  }
  return zones.where((z) {
    final d = _distanceMiles(
      observerLat,
      observerLng,
      z.centerLat,
      z.centerLng,
    );
    return d <= radiusMiles;
  }).toList();
}

double _distanceMiles(double lat1, double lng1, double lat2, double lng2) {
  const r = 3958.8;
  final dLat = (lat2 - lat1) * (3.141592653589793 / 180.0);
  final dLng = (lng2 - lng1) * (3.141592653589793 / 180.0);
  final a =
      (sin(dLat / 2) * sin(dLat / 2)) +
      cos(lat1 * (3.141592653589793 / 180.0)) *
          cos(lat2 * (3.141592653589793 / 180.0)) *
          (sin(dLng / 2) * sin(dLng / 2));
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}
