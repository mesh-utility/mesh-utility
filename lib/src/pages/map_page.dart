import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:mesh_utility/src/models/coverage_zone.dart';
import 'package:mesh_utility/src/models/raw_scan.dart';
import 'package:mesh_utility/src/models/scan_result.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/grid.dart';
import 'package:mesh_utility/src/services/hex_detail.dart';
import 'package:mesh_utility/src/services/map_camera.dart';
import 'package:mesh_utility/src/services/map_viewport_render.dart';
import 'package:mesh_utility/src/services/mesh_stage_log.dart';
import 'package:mesh_utility/src/services/radio_id_utils.dart';
import 'package:mesh_utility/src/services/signal_class.dart';
import 'package:mesh_utility/src/services/tile_cache_service.dart';
import 'package:mesh_utility/src/widgets/map_page_widgets.dart';
import 'package:mesh_utility/src/widgets/coverage_hex_batch_layer.dart';
import 'package:mesh_utility/src/widgets/map_top_controls.dart';
import 'dart:math';

enum BaseLayer { dark, standard, satellite }

/// How long an overlay-button tap can still be delivered to the map.
///
/// flutter_map confirms a tap after its double-tap window (250ms). A layer
/// or upload tap in that window must not select a hex.
const Duration mapOverlayHitSuppressWindow = Duration(milliseconds: 350);

/// True when [focusHexId] should open the coverage popup.
///
/// Applying it again because the zone list was rebuilt (sync, upload, tiles)
/// re-opens a popup the user already closed. A new id clears that latch.
bool shouldApplyMapHexFocus({
  required String? focusHexId,
  required String? appliedFocusHexId,
  required bool suppressed,
}) {
  if (suppressed) return false;
  if (focusHexId == null || focusHexId.isEmpty) return false;
  if (focusHexId == appliedFocusHexId) return false;
  return true;
}

class MapPage extends StatefulWidget {
  const MapPage({
    super.key,
    required this.zones,
    this.onViewportHexes,
    this.onFetchHexDetail,
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
    this.onTapNodes,
    this.onTapScans,
    this.onClearFocusNodeId,
    this.onClearFocusHexId,
  });

  final List<CoverageZone> zones;
  final Future<void> Function({
    double? south,
    double? north,
    double? west,
    double? east,
    bool force,
  })?
  onViewportHexes;
  final Future<List<RawScan>> Function(String zoneId)? onFetchHexDetail;
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
  final VoidCallback? onTapNodes;
  final VoidCallback? onTapScans;
  final VoidCallback? onClearFocusNodeId;

  /// Clears a one-shot "open this hex" request after the map page leaves.
  /// Without this, creating the page again selects the hex and the popup
  /// is still there when the user comes back.
  final VoidCallback? onClearFocusHexId;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  final AppDebugLogService _debugLog = AppDebugLogService.instance;
  BaseLayer _baseLayer = BaseLayer.standard;
  Brightness? _lastThemeBrightness;
  bool _layerSelectorExpanded = false;
  bool _legendExpanded = false;
  double _mapViewportHeight = 700;
  CoverageZone? _selectedZone;

  /// Focus id that already opened the popup. Zone-list rebuilds must not
  /// apply it again.
  String? _appliedFocusHexId;

  /// Node focus that already moved the camera. A Nodes-tab tap can arrive
  /// before the viewport index has the node's cells; the focus then waits
  /// for the zone list instead of being dropped.
  String? _appliedFocusNodeId;

  /// Set when the popup is dismissed, the page pauses, or a modal opens.
  /// Stays set until [MapPage.focusHexId] changes to a new id.
  bool _suppressHexFocus = false;

  /// Map taps that arrive while this is in the future must not select a hex.
  DateTime? _blockHexSelectUntil;

  /// Last pointer kind seen on the map, used to pick hex tap slop.
  PointerDeviceKind _hexTapKind = PointerDeviceKind.touch;
  bool _modalDismissQueued = false;
  String? _lastNodeFilterDebugSignature;
  String? _lastPopupDebugSignature;
  LatLng? _lastAutoCenterTarget;
  DateTime? _lastAutoCenterDisableAt;
  Set<String> _selectedNodeFilters = <String>{};
  late TileProvider _tileProvider;
  Timer? _viewportRenderTimer;
  DateTime? _viewportBurstStart;
  bool _renderPosted = false;
  bool _renderReady = false;
  int? _filterIdentity;
  int _renderRequest = 0;
  final HexRenderSession _hexSession = HexRenderSession();
  List<CoverageZone> _datasetZones = const [];
  int _renderSignature = 0;
  List<CoverageBatchHex> _batchHexes = const [];

  /// Drives only the hex layer, so an in-view refresh does not rebuild the
  /// whole map page (stats, legend, popup) mid-gesture.
  final ValueNotifier<List<CoverageBatchHex>> _batchHexesView =
      ValueNotifier<List<CoverageBatchHex>>(const []);

  /// Batch hexes by zone id, reused across in-view refreshes so the layer
  /// keeps their projected outlines. Cleared with the dataset.
  final Map<String, _BatchHexMemo> _batchHexMemo = <String, _BatchHexMemo>{};
  List<MapDrawPolygon> _drawnPolygons = const [];
  MapDrawPolygon? _clusterPopup;
  MapRenderViewport? _appliedViewport;
  _MapDataset? _dataset;
  final _ScopedNodeKeysMemo _scopedNodeKeysMemo = _ScopedNodeKeysMemo();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tileProvider = TileCacheService.createTileProvider(
      enabled: widget.tileCachingEnabled,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_mapReady) {
        _runInitialFocus();
      } else {
        _initialFocusPending = true;
      }
    });
  }

  /// FlutterMap has finished its first layout and the tile layer is listening
  /// for camera moves.
  bool _mapReady = false;

  /// Page-open focus (node or hex from another page, or own fix) waits for
  /// [_mapReady], as flutter_map asks for controller moves.
  bool _initialFocusPending = false;

  void _runInitialFocus() {
    // A node or hex focus from another page wins over own-fix auto-center.
    // Running both moved the camera off the node's coverage to the GPS fix.
    final focused = _focusHexIfRequested();
    if (!focused) _maybeAutoCenterOnObserver();
  }

  void _handleMapReady() {
    _mapReady = true;
    _scheduleViewportRender(immediate: true);
    if (!_initialFocusPending) return;
    _initialFocusPending = false;
    // flutter_map sends its first size event one frame after the map is
    // built, carrying the camera from that build (the initial z10 view).
    // A page-open jump made before it (node tap on the Nodes page) left the
    // tile layer loading tiles for that stale camera and pruning the new
    // ones: blank map until the next pan. Jump on the following frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _runInitialFocus();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_lastThemeBrightness != brightness) {
      _lastThemeBrightness = brightness;
      _baseLayer = _defaultBaseLayerForBrightness(brightness);
    }
    _dismissHexPopupIfCoveredByModal();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _dismissHexPopup('app paused');
    }
  }

  @override
  void deactivate() {
    // Page leave (Cell History and the other tabs replace this page).
    // Clear local selection and ask the owner to drop the one-shot focus so
    // the next visit does not open the popup again.
    _clearHexPopupFields('page deactivated');
    final clearFocus = widget.onClearFocusHexId;
    super.deactivate();
    if (clearFocus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => clearFocus());
    }
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
    final focusChanged = widget.focusHexId != oldWidget.focusHexId;
    if (focusChanged && (widget.focusHexId ?? '').isNotEmpty) {
      _suppressHexFocus = false;
      _appliedFocusHexId = null;
    }
    final focusNeedsApply = shouldApplyMapHexFocus(
      focusHexId: widget.focusHexId,
      appliedFocusHexId: _appliedFocusHexId,
      suppressed: _suppressHexFocus,
    );
    // Zone-list identity changes on sync, upload, and tile refresh. Those
    // rebuilds must not re-select a hex that was already shown or dismissed.
    if (widget.focusNodeId != oldWidget.focusNodeId) {
      _appliedFocusNodeId = null;
    }
    final nodeFocusPending =
        (widget.focusNodeId ?? '').isNotEmpty &&
        _appliedFocusNodeId != widget.focusNodeId;
    if (focusChanged ||
        widget.focusNodeId != oldWidget.focusNodeId ||
        (widget.zones != oldWidget.zones &&
            (focusNeedsApply || nodeFocusPending))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusHexIfRequested();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _viewportRenderTimer?.cancel();
    _tileProvider.dispose();
    _batchHexesView.dispose();
    super.dispose();
  }

  bool get _hexPopupOpen => _selectedZone != null || _clusterPopup != null;

  void _clearHexPopupFields([String reason = 'clear']) {
    if (_hexPopupOpen) {
      _debugLog.info('popup', 'Hex popup closed reason=$reason');
    }
    _suppressHexFocus = true;
    _selectedZone = null;
    _clusterPopup = null;
    _lastPopupDebugSignature = null;
  }

  /// Drops the coverage popup and blocks focus from opening it again.
  void _dismissHexPopup([String reason = 'dismiss']) {
    _suppressHexFocus = true;
    if (!_hexPopupOpen) return;
    _clearHexPopupFields(reason);
    if (!mounted) return;
    setState(() {});
  }

  void _markOverlayInteraction() {
    _blockHexSelectUntil = DateTime.now().add(mapOverlayHitSuppressWindow);
  }

  bool get _blockHexSelect {
    final until = _blockHexSelectUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _dismissHexPopupIfCoveredByModal() {
    final route = ModalRoute.of(context);
    if (route == null || route.isCurrent) {
      _modalDismissQueued = false;
      return;
    }
    if (!_hexPopupOpen || _modalDismissQueued) return;
    _modalDismissQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _modalDismissQueued = false;
      if (!mounted) return;
      final current = ModalRoute.of(context);
      if (current != null && !current.isCurrent) {
        _dismissHexPopup('covered by modal');
      }
    });
  }

  /// Prefer the painted hex under the finger, then the nearest center
  /// within the pointer's tap radius.
  ///
  /// Taps are in screen space; the rings are painted in unrotated layer
  /// space ([coverageHexLayerOffset]). Convert the tap into that space
  /// before hit-testing so rotation matches the painted hexes.
  String? _hitCoverage(
    TapPosition tapPosition,
    LatLng latLng,
    List<CoverageBatchHex> hexes,
  ) {
    final relative = tapPosition.relative;
    if (relative != null) {
      try {
        final camera = _mapController.camera;
        Offset project(LatLng point) => coverageHexLayerOffset(camera, point);
        final layerPoint = coverageHexScreenToLayer(camera, relative);
        final radius = switch (_hexTapKind) {
          PointerDeviceKind.touch ||
          PointerDeviceKind.unknown => kHexTapRadiusTouch,
          PointerDeviceKind.mouse ||
          PointerDeviceKind.stylus ||
          PointerDeviceKind.invertedStylus ||
          PointerDeviceKind.trackpad => kHexTapRadiusMouse,
        };
        return hitTestCoverageBatchHexesNearest(
          layerPoint,
          hexes,
          project,
          radius: radius,
        );
      } catch (_) {
        // Camera is not ready yet. Fall through to the geographic test.
      }
    }
    return hitTestCoverageBatchHexes(latLng, hexes);
  }

  void _noteDataset(List<CoverageZone> zones, int identity) {
    if (identity == _filterIdentity) return;
    _filterIdentity = identity;
    _datasetZones = zones;
    _renderRequest++;
    _hexSession.reset(identity);
    _renderReady = false;
    _batchHexes = const [];
    _batchHexesView.value = _batchHexes;
    _batchHexMemo.clear();
    _drawnPolygons = const [];
    _clusterPopup = null;
    _appliedViewport = null;
    _scheduleViewportRender(immediate: true);
  }

  void _scheduleViewportRender({bool immediate = false}) {
    if (immediate) {
      _viewportBurstStart = null;
      _viewportRenderTimer?.cancel();
      _viewportRenderTimer = null;
      _enqueueViewportRender();
      return;
    }
    final now = DateTime.now();
    _viewportBurstStart ??= now;
    final delay = mapViewportRefreshDelay(
      sinceBurst: now.difference(_viewportBurstStart!),
    );
    _viewportRenderTimer?.cancel();
    if (delay == Duration.zero) {
      _viewportRenderTimer = null;
      _viewportBurstStart = now;
      _enqueueViewportRender();
      return;
    }
    _viewportRenderTimer = Timer(delay, () {
      _viewportRenderTimer = null;
      _viewportBurstStart = null;
      _enqueueViewportRender();
    });
  }

  void _enqueueViewportRender() {
    if (_renderPosted) return;
    _renderPosted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renderPosted = false;
      if (!mounted) return;
      _recomputeViewportRender();
    });
  }

  MapRenderViewport? _readViewport() {
    final MapCamera camera;
    try {
      camera = _mapController.camera;
    } catch (_) {
      return null;
    }
    final size = camera.nonRotatedSize;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      return null;
    }
    try {
      final bounds = camera.visibleBounds;
      return MapRenderViewport.fromCenterWidth(
        south: bounds.south,
        north: bounds.north,
        longitudeCenter: bounds.longitudeCenter,
        longitudeWidth: bounds.longitudeWidth,
        zoom: camera.zoom,
      );
    } catch (_) {
      return null;
    }
  }

  void _recomputeViewportRender() {
    if (!mounted || _filterIdentity == null) return;
    final viewport = _readViewport();
    if (viewport == null) return;
    // Camera events keep arriving after a dataset lands even when nothing
    // moved. Re-entering here copied the zone list and culled it again on
    // the UI isolate.
    if (_renderReady &&
        _appliedViewport != null &&
        _sameViewport(_appliedViewport!, viewport)) {
      return;
    }
    final request = ++_renderRequest;
    final identity = _filterIdentity!;
    unawaited(_finishViewportRender(request: request, identity: identity));
  }

  Future<void> _finishViewportRender({
    required int request,
    required int identity,
  }) async {
    final watch = Stopwatch()..start();
    final zones = _datasetZones.length;
    final announce = zones >= 250;
    if (announce) meshStageStart('viewport_render', count: zones);
    var drawn = -1;
    try {
      MapRenderViewport? pending = _readViewport();
      for (var pass = 0; pass < 4; pass++) {
        final viewport = pending;
        if (viewport == null) return;
        if (!mounted ||
            request != _renderRequest ||
            identity != _filterIdentity) {
          return;
        }
        final plan = await _hexSession.render(
          identity: identity,
          zones: _datasetZones,
          viewport: viewport,
        );
        if (!mounted || plan == null || request != _renderRequest) return;
        if (identity != _filterIdentity) return;
        final latest = _readViewport();
        if (latest == null) return;
        if (_sameViewport(latest, viewport)) {
          drawn = plan.polygons.length;
          _applyPlan(plan, viewport);
          return;
        }
        pending = latest;
      }
    } finally {
      final elapsed = watch.elapsedMilliseconds;
      if (announce || elapsed >= 50) {
        meshStageEnd('viewport_render', count: zones, ms: elapsed, n2: drawn);
      }
    }
  }

  void _applyPlan(MapRenderPlan plan, MapRenderViewport viewport) {
    final signature = mapDrawSignature(plan.polygons);
    final sameDraw = _renderReady && signature == _renderSignature;
    final sameView =
        _appliedViewport != null && _sameViewport(_appliedViewport!, viewport);
    if (sameDraw && sameView) return;
    if (!sameDraw) {
      _renderReady = true;
      _renderSignature = signature;
      _drawnPolygons = plan.polygons;
      _batchHexes = _batchHexesForDraw(plan.polygons, _batchHexMemo);
      _batchHexesView.value = _batchHexes;
    }
    _appliedViewport = viewport;
    final onViewport = widget.onViewportHexes;
    if (onViewport != null) {
      unawaited(
        onViewport(
          south: viewport.south,
          north: viewport.north,
          west: viewport.west,
          east: viewport.east,
          force: false,
        ),
      );
    }
    final heavy = plan.polygons.length >= mapHeavyTrueSizeDrawCount
        ? ' heavy=true'
        : '';
    _debugLog.debug(
      'map_render',
      'polygons=${_batchHexes.length} dataset=${_datasetZones.length} '
          'zoom=${viewport.zoom.toStringAsFixed(2)} '
          'scale=${plan.scale}$heavy',
    );
  }

  bool _sameViewport(MapRenderViewport a, MapRenderViewport b) {
    const epsilon = 1e-9;
    return (a.zoom - b.zoom).abs() < epsilon &&
        (a.south - b.south).abs() < epsilon &&
        (a.north - b.north).abs() < epsilon &&
        (a.west - b.west).abs() < epsilon &&
        (a.east - b.east).abs() < epsilon &&
        a.crossesAntimeridian == b.crossesAntimeridian &&
        a.spansAllLongitudes == b.spansAllLongitudes;
  }

  MapDrawPolygon? _drawForZoneId(String zoneId) {
    for (final draw in _drawnPolygons) {
      if (draw.hitZoneId == zoneId) return draw;
    }
    for (final draw in _drawnPolygons) {
      if (draw.containsZone(zoneId)) return draw;
    }
    return null;
  }

  bool _hexDetailLoaded = false;
  List<RawScan> _hexDetailScans = const <RawScan>[];
  String? _hexDetailZoneId;
  bool _hexDetailLoading = false;

  void _loadHexDetail(CoverageZone zone) {
    final fetch = widget.onFetchHexDetail;
    if (fetch == null || parseHexDetailId(zone.id) == null) {
      _hexDetailScans = const <RawScan>[];
      _hexDetailZoneId = null;
      _hexDetailLoading = false;
      _hexDetailLoaded = false;
      return;
    }
    _hexDetailScans = const <RawScan>[];
    _hexDetailZoneId = zone.id;
    _hexDetailLoading = true;
    _hexDetailLoaded = false;
    fetch(zone.id).then((scans) {
      if (!mounted || _hexDetailZoneId != zone.id) return;
      setState(() {
        _hexDetailScans = scans;
        _hexDetailLoading = false;
        _hexDetailLoaded = true;
        _lastPopupDebugSignature = null;
      });
    });
  }

  void _handleBatchHit(String zoneId) {
    _debugLog.info('ui_click', 'Map hex click zone=$zoneId');
    CoverageZone? zone;
    for (final z in widget.zones) {
      if (z.id == zoneId) {
        zone = z;
        break;
      }
    }
    if (zone != null) {
      _suppressHexFocus = true;
      _disableAutoCenter('popup open');
      final draw = _drawForZoneId(zoneId);
      setState(() {
        _selectedZone = zone;
        _clusterPopup = draw != null && draw.scale > 1 ? draw : null;
        _legendExpanded = false;
        _lastPopupDebugSignature = null;
      });
      _loadHexDetail(zone);
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
    final targetZoom = capFocusZoom(16.4);
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
    final alreadyCentered = _lastAutoCenterTarget != null;
    if (alreadyCentered) {
      final movedMiles = distanceMiles(
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
    final zoom = zoomAfterOwnFixArrives(
      currentZoom: _mapController.camera.zoom,
      alreadyCenteredOnOwnFix: alreadyCentered,
    );
    _lastAutoCenterTarget = target;
    _debugLog.debug(
      'map_auto_center',
      'Recenter to lat=${target.latitude.toStringAsFixed(6)} '
          'lng=${target.longitude.toStringAsFixed(6)} zoom=${zoom.toStringAsFixed(2)}',
    );
    _mapController.move(target, zoom);
  }

  Future<void> _handleAutoCenterToggleFromControls() async {
    _markOverlayInteraction();
    _debugLog.info('ui_click', 'Map controls auto-center toggle');
    final nextValue = !widget.autoCenter;
    await widget.onToggleAutoCenter(nextValue);
    if (!mounted || !nextValue) return;

    final lat = widget.observerLat;
    final lng = widget.observerLng;
    if (lat == null || lng == null) return;

    if (_hexPopupOpen) {
      _dismissHexPopup('auto-center on');
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

  /// Applies a pending node or hex focus. True when the camera was moved.
  bool _focusHexIfRequested() {
    if (_focusNodeIfRequested()) return true;
    final hexId = widget.focusHexId;
    if (!shouldApplyMapHexFocus(
      focusHexId: hexId,
      appliedFocusHexId: _appliedFocusHexId,
      suppressed: _suppressHexFocus,
    )) {
      return false;
    }
    CoverageZone? zone;
    for (final z in widget.zones) {
      if (z.id == hexId) {
        zone = z;
        break;
      }
    }
    if (zone == null || !mounted) return false;
    _appliedFocusHexId = hexId;
    setState(() {
      _selectedZone = zone;
      _clusterPopup = null;
      _legendExpanded = false;
      _lastPopupDebugSignature = null;
    });
    _loadHexDetail(zone);
    _focusZone(zone);
    return true;
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
        nodeHexes.addAll(
          coverageZoneIdsForPoint(scan.latitude, scan.longitude),
        );
      }
    }
    if (nodeHexes.isEmpty) {
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
    if (_appliedFocusNodeId == nodeId) return false;
    _appliedFocusNodeId = nodeId;
    _disableAutoCenter('node focus');
    if (_hexPopupOpen) {
      _debugLog.info('popup', 'Hex popup closed reason=node focus');
    }
    setState(() {
      // Node-focus mode should not auto-open a zone popup.
      _selectedZone = null;
      _clusterPopup = null;
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
        maxZoom: capFocusZoom(16.2),
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
        nodeHexes.addAll(
          coverageZoneIdsForPoint(scan.latitude, scan.longitude),
        );
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
    _disableAutoCenter('node filter focus');
    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: coordinates,
        padding: const EdgeInsets.fromLTRB(24, 120, 56, 130),
        maxZoom: capFocusZoom(16.2),
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

  List<ScanResult> _filterScansByRadius(List<ScanResult> scans) {
    final radius = widget.statsRadiusMiles;
    final lat = widget.observerLat;
    final lng = widget.observerLng;
    if (radius == 0 || lat == null || lng == null) return scans;
    return scans.where((s) {
      return distanceMiles(lat, lng, s.latitude, s.longitude) <= radius;
    }).toList();
  }

  Future<void> _openNodeFilterDialog() async {
    // Close the hex popup before the route is pushed so the dialog does not
    // stack on top of it.
    _markOverlayInteraction();
    _dismissHexPopup('node filter dialog');
    // Respect Stats Radius so only nodes with scans inside the radius appear.
    final radiusScans = _filterScansByRadius(widget.scans);
    final options = _nodeFilterOptions(
      scans: radiusScans,
      resolvedNodeNames: widget.resolvedNodeNames,
    );
    if (!mounted) return;
    final selected = Set<String>.from(
      _effectiveNodeFilters(
        focusNodeId: widget.focusNodeId,
        selectedNodeFilters: _selectedNodeFilters,
      ),
    );
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) =>
          _NodeFilterDialog(options: options, initiallySelected: selected),
    );
    if (!mounted || result == null) return;
    final signatureBefore = selected.toList()..sort();
    final signatureAfter = result.toList()..sort();
    if (signatureBefore.join(',') == signatureAfter.join(',')) {
      return;
    }
    _debugLog.info(
      'map_filter',
      'Node filter updated: count=${result.length} ids=${signatureAfter.join(',')}',
    );
    // Manual filter changes should override one-shot focus routing from
    // other pages so "clear filter" truly clears map filtering state.
    final hadFocusNode = (widget.focusNodeId ?? '').trim().isNotEmpty;
    if (hadFocusNode) {
      widget.onClearFocusNodeId?.call();
    }
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
        _clusterPopup = null;
        _lastPopupDebugSignature = null;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusCoverageForNodeFilters(result);
    });
  }

  _MapDataset _datasetFor({
    required String? focusNodeId,
    required Set<String> effectiveNodeFilters,
  }) {
    final cached = _dataset;
    final filterHash = _filterHash(effectiveNodeFilters);
    if (cached != null &&
        identical(cached.zones, widget.zones) &&
        identical(cached.scans, widget.scans) &&
        cached.radius == widget.statsRadiusMiles &&
        cached.lat == widget.observerLat &&
        cached.lng == widget.observerLng &&
        cached.focusNodeId == focusNodeId &&
        cached.selectedCount == _selectedNodeFilters.length &&
        cached.filterHash == filterHash) {
      _noteDataset(cached.filtered, cached.identity);
      return cached;
    }

    final watch = Stopwatch()..start();
    final baseZones = effectiveNodeFilters.isEmpty
        ? widget.zones
        : () {
            final nodeHexes = <String>{};
            for (final scan in widget.scans) {
              final key = _nodeFilterKey(scan.nodeId);
              if (key.isNotEmpty && effectiveNodeFilters.contains(key)) {
                nodeHexes.addAll(
                  coverageZoneIdsForPoint(scan.latitude, scan.longitude),
                );
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
    final identity = coverageFilterIdentity(filteredZones);
    // Filters already ran. Aggregation and the polygon cache see only this list.
    _noteDataset(filteredZones, identity);
    final filteredZoneIds = filteredZones.map((z) => z.id).toSet();
    final scopedNodeIds = <String>{};
    for (final scan in widget.scans) {
      final nodeKey = _nodeFilterKey(scan.nodeId);
      if (nodeKey.isEmpty) continue;
      if (effectiveNodeFilters.isNotEmpty &&
          !effectiveNodeFilters.contains(nodeKey)) {
        continue;
      }
      if (filteredZoneIds
          .intersection(coverageZoneIdsForPoint(scan.latitude, scan.longitude))
          .isEmpty) {
        continue;
      }
      scopedNodeIds.add(nodeKey);
    }
    // Index-fed map: raw scans are often not loaded, so also count the heard
    // nodes the hex index lists for the shown cells (same data as the map).
    scopedNodeIds.addAll(
      _scopedNodeKeysMemo.keysFor(filteredZones, effectiveNodeFilters),
    );
    if (effectiveNodeFilters.isNotEmpty) {
      final filterLabel = _selectedNodeFilters.isNotEmpty
          ? 'custom(${effectiveNodeFilters.length})'
          : focusNodeId!;
      final signature =
          '$filterLabel|zones:${widget.zones.length}|base:${baseZones.length}|filtered:${filteredZones.length}|radiusBypass:$bypassRadiusForNodeFocus';
      if (signature != _lastNodeFilterDebugSignature) {
        _lastNodeFilterDebugSignature = signature;
        _debugLog.debug(
          'map_filter',
          'Render filter active for $filterLabel: base=${baseZones.length}, afterRadius=${filteredZones.length}, radiusBypass=$bypassRadiusForNodeFocus',
        );
      }
    } else {
      _lastNodeFilterDebugSignature = null;
    }
    var active = 0;
    var dead = 0;
    var rssiSum = 0.0;
    var snrSum = 0.0;
    for (final zone in filteredZones) {
      if (zone.isDeadZone) {
        dead += 1;
        continue;
      }
      active += 1;
      rssiSum += zone.avgRssi ?? 0;
      snrSum += zone.avgSnr ?? 0;
    }
    final next = _MapDataset(
      zones: widget.zones,
      scans: widget.scans,
      radius: widget.statsRadiusMiles,
      lat: widget.observerLat,
      lng: widget.observerLng,
      focusNodeId: focusNodeId,
      selectedCount: _selectedNodeFilters.length,
      filterHash: filterHash,
      filtered: filteredZones,
      identity: identity,
      scopedNodes: scopedNodeIds.length,
      active: active,
      dead: dead,
      avgRssi: active == 0 ? 0 : rssiSum / active,
      avgSnr: active == 0 ? 0 : snrSum / active,
    );
    _dataset = next;
    final elapsed = watch.elapsedMilliseconds;
    if (widget.zones.length >= 250 ||
        widget.scans.length >= 250 ||
        elapsed >= 50) {
      meshStageEnd(
        'map_dataset',
        count: widget.zones.length,
        ms: elapsed,
        n2: widget.scans.length,
      );
    }
    return next;
  }

  int _filterHash(Set<String> filters) {
    if (filters.isEmpty) return 0;
    final ordered = filters.toList()..sort();
    return Object.hashAll(ordered);
  }

  /// Base map tiles. The dark basemap uses the same invert + hue-rotate
  /// matrix as flutter_map's darkModeTileBuilder, but applied once to the
  /// whole tile layer instead of once per tile. Per-tile ColorFiltered adds a
  /// save layer for every tile, and during pinch-zoom two zoom levels of
  /// tiles are on screen, which was the main raster cost of zooming.
  int _tileErrorCount = 0;

  void _onTileError(TileImage tile, Object error, StackTrace? stackTrace) {
    _tileErrorCount++;
    // Log the first few and then every 25th so a dead network cannot flood.
    if (_tileErrorCount <= 5 || _tileErrorCount % 25 == 0) {
      final c = tile.coordinates;
      _debugLog.warn(
        'map_tiles',
        'Tile load failed z=${c.z} x=${c.x} y=${c.y} '
            'count=$_tileErrorCount: $error',
      );
    }
  }

  Widget _baseTileLayer() {
    final tiles = TileLayer(
      urlTemplate: _layerTemplate(_baseLayer),
      userAgentPackageName: 'mesh_utility',
      tileProvider: _tileProvider,
      // Past the servers' native zoom, scale up the z19 tiles. TileLayer
      // draws nothing at all once the camera zoom rounds above its maxZoom,
      // which was the blank light-gray map when zoomed in past 19.5.
      maxNativeZoom: basemapMaxNativeZoom.toInt(),
      maxZoom: mapMaxZoom,
      // A tile that failed (timeout, 5xx) is dropped once it leaves the view
      // so it is fetched again next time instead of staying blank.
      evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
      errorTileCallback: _onTileError,
    );
    if (_baseLayer != BaseLayer.dark) return tiles;
    return ColorFiltered(colorFilter: darkBasemapTileFilter, child: tiles);
  }

  @override
  Widget build(BuildContext context) {
    // Own fix, or the general US view. Coverage zones must not move this.
    final camera = initialMapCamera(
      ownLatitude: widget.observerLat,
      ownLongitude: widget.observerLng,
    );
    final center = LatLng(camera.latitude, camera.longitude);

    final focusNodeId = widget.focusNodeId;
    final effectiveNodeFilters = _effectiveNodeFilters(
      focusNodeId: focusNodeId,
      selectedNodeFilters: _selectedNodeFilters,
    );
    final dataset = _datasetFor(
      focusNodeId: focusNodeId,
      effectiveNodeFilters: effectiveNodeFilters,
    );
    final scopedNodesCount = dataset.scopedNodes;
    final activeZonesLength = dataset.active;
    final deadZonesLength = dataset.dead;
    final avgRssi = dataset.avgRssi;
    final avgSnr = dataset.avgSnr;
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
        final legendExpandedWidth = min(viewWidth - 24, 196.0);
        final legendReservedWidth = 56.0;
        // Cap the hex popup so a 360dp phone keeps margins and long lines wrap
        // inside the card instead of running off the screen.
        final popupWidth = min(280.0, max(120.0, viewWidth - 24));
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
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  _hexTapKind = event.kind;
                },
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: camera.zoom,
                    maxZoom: mapMaxZoom,
                    // Behind tiles that are still loading. The dark basemap
                    // keeps a dark backdrop instead of flashing light gray.
                    backgroundColor: _baseLayer == BaseLayer.dark
                        ? darkBasemapBackground
                        : const Color(0xFFE0E0E0),
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all,
                    ),
                    onPositionChanged: (_, hasGesture) {
                      if (hasGesture) {
                        _disableAutoCenter('map gesture');
                      }
                    },
                    onMapReady: _handleMapReady,
                    onMapEvent: (event) {
                      if (event is MapEventNonRotatedSizeChange) {
                        _scheduleViewportRender(immediate: true);
                      } else if (event is MapEventWithMove) {
                        _scheduleViewportRender();
                      }
                    },
                    onTap: (tapPosition, latLng) {
                      _disableAutoCenter('map tap');
                      final hitId = _hitCoverage(
                        tapPosition,
                        latLng,
                        _batchHexes,
                      );
                      if (hitId == null) {
                        _debugLog.debug(
                          'ui_click',
                          'Map background click clear popup at lat=${latLng.latitude.toStringAsFixed(6)} lng=${latLng.longitude.toStringAsFixed(6)}',
                        );
                        _dismissHexPopup('empty map tap');
                        return;
                      }
                      // A layer/upload tap can still be delivered here after the
                      // overlay rebuilds. That must not select a hex.
                      if (_blockHexSelect) return;
                      _handleBatchHit(hitId);
                    },
                  ),
                  children: [
                    _baseTileLayer(),
                    if (widget.observerLat != null &&
                        widget.observerLng != null)
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
                                        BorderSide(
                                          color: Colors.white,
                                          width: 2,
                                        ),
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
                    // [_batchHexes] is only ever replaced, never mutated, so
                    // the layer can reuse its projected geometry by identity.
                    ValueListenableBuilder<List<CoverageBatchHex>>(
                      valueListenable: _batchHexesView,
                      builder: (context, hexes, _) => hexes.isEmpty
                          ? const SizedBox.shrink()
                          : CoverageHexBatchLayer(hexes: hexes),
                    ),
                  ],
                ),
              ),
            ),
            // Above the map, under the controls. An empty-map tap dismisses
            // the popup. Filter, layer, and upload stay tappable and close
            // this popup before they open their own modal.
            if (_selectedZone != null)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _debugLog.info('ui_click', 'Popup scrim click close popup');
                    _dismissHexPopup('scrim tap');
                  },
                  child: Container(color: Colors.black.withValues(alpha: 0.42)),
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
                      _markOverlayInteraction();
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
                          children: const [
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
                              color: deadZoneMapColor,
                              text: 'Dead Zone',
                              range: 'No response',
                              fillOpacity: legendDeadZoneFillOpacity,
                            ),
                            LegendRow(
                              color: Color(0xFFA855F7),
                              text: 'Noisy',
                              range: 'Good signal, bad SNR',
                            ),
                            LegendRow(
                              color: Color(0xFF3B82F6),
                              text: 'You',
                              range: 'This device',
                              marker: LegendLocationDot(),
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
                      _markOverlayInteraction();
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
                            LegendSwatch(
                              color: deadZoneMapColor,
                              fillOpacity: legendDeadZoneFillOpacity,
                            ),
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
                            _markOverlayInteraction();
                            _openNodeFilterDialog();
                          },
                          icon: const Icon(Icons.filter_alt),
                          tooltip: 'Filter repeater hits',
                        ),
                        if (effectiveNodeFilters.isNotEmpty)
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
                                    _markOverlayInteraction();
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
                                    _markOverlayInteraction();
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
                                    _markOverlayInteraction();
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
                              _markOverlayInteraction();
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
                  _markOverlayInteraction();
                  _debugLog.info('ui_click', 'Map controls scan toggle click');
                  widget.onBleToggleScan();
                },
                onForceScan: () {
                  _markOverlayInteraction();
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
                  _markOverlayInteraction();
                  _debugLog.info('ui_click', 'Map controls sync click');
                  widget.onRefresh();
                },
                onBeforeDialog: _dismissHexPopup,
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
                      activeZones: activeZonesLength,
                      deadZones: deadZonesLength,
                      avgRssi: avgRssi,
                      avgSnr: avgSnr,
                      statsRadiusMiles: widget.statsRadiusMiles,
                      unitSystem: widget.unitSystem,
                      hasObserver:
                          widget.observerLat != null &&
                          widget.observerLng != null,
                      onTapNodes: widget.onTapNodes,
                      onTapScans: widget.onTapScans,
                    ),
                  );
                },
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
                      final cachedLatest = _latestScanForZone(
                        _selectedZone!,
                        widget.scans,
                        nodeIdFilters: effectiveNodeFilters,
                      );
                      // Same observer name and SNR in as Cell History once
                      // the tapped cell's detail has loaded.
                      final latest = cachedLatest == null
                          ? null
                          : enrichScanWithHexDetail(
                              cachedLatest,
                              _hexDetailScans,
                            );
                      final latestRaw = latest == null
                          ? _latestRawScanForZone(
                              _selectedZone!,
                              _hexDetailScans.isEmpty
                                  ? widget.rawScans
                                  : <RawScan>[
                                      ...widget.rawScans,
                                      ..._hexDetailScans,
                                    ],
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
                      final rawCluster = _clusterPopup;
                      final MapDrawPolygon? cluster =
                          rawCluster != null && rawCluster.scale > 1
                          ? rawCluster
                          : null;
                      final popupNodeLabel = latest != null
                          ? _stripPopupEntityLabel(
                              _nodeDisplayName(
                                latest.senderName,
                                latest.nodeId,
                                resolvedNameForNodeId(
                                  widget.resolvedNodeNames,
                                  latest.nodeId,
                                ),
                              ),
                            )
                          : (latestRaw != null
                                ? _stripPopupEntityLabel(
                                    _nodeDisplayName(
                                      latestRaw.senderName,
                                      latestRaw.nodeId ??
                                          latestRaw.observerId ??
                                          '',
                                      resolvedNameForNodeId(
                                        widget.resolvedNodeNames,
                                        latestRaw.nodeId ??
                                            latestRaw.observerId ??
                                            '',
                                      ),
                                    ),
                                  )
                                : '');
                      final popupSig = latest != null
                          ? 'zone=${_selectedZone!.id}|ts=${latest.timestamp.toIso8601String()}|node=${latest.nodeId}|obs=${_observerDisplayName(latest, connectedRadioName: widget.connectedRadioName, connectedRadioMeshId: widget.connectedRadioMeshId, resolvedNodeNames: widget.resolvedNodeNames)}|rssi=${latest.rssi.toStringAsFixed(1)}|snrOut=${latest.snr?.toStringAsFixed(1) ?? 'N/A'}|snrIn=${latest.snrIn?.toStringAsFixed(1) ?? 'N/A'}|alt=${latest.altitude?.toStringAsFixed(1) ?? 'N/A'}|scans=${_selectedZone!.scanCount}|dead=$effectiveDead'
                          : (latestRaw != null
                                ? 'zone=${_selectedZone!.id}|raw-fallback|ts=${latestRaw.effectiveTimestamp.toIso8601String()}|node=${latestRaw.nodeId ?? ''}|obs=${_observerDisplayNameRaw(latestRaw, connectedRadioName: widget.connectedRadioName, connectedRadioMeshId: widget.connectedRadioMeshId, resolvedNodeNames: widget.resolvedNodeNames)}|rssi=${latestRaw.rssi?.toStringAsFixed(1) ?? 'N/A'}|snrOut=${latestRaw.snr?.toStringAsFixed(1) ?? 'N/A'}|snrIn=${latestRaw.snrIn?.toStringAsFixed(1) ?? 'N/A'}|alt=${latestRaw.altitude?.toStringAsFixed(1) ?? 'N/A'}|scans=${_selectedZone!.scanCount}|dead=$effectiveDead'
                                : 'zone=${_selectedZone!.id}|no-scan|scans=${_selectedZone!.scanCount}|dead=$effectiveDead');
                      final clusterSig = cluster == null
                          ? ''
                          : '|cluster=${cluster.childCount}|heard=${cluster.coveredCount}|scale=${cluster.scale}';
                      final popupSignature = '$popupSig$clusterSig';
                      if (popupSignature != _lastPopupDebugSignature) {
                        _lastPopupDebugSignature = popupSignature;
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
                                    cluster != null
                                        ? (cluster.coveredCount == 0
                                              ? 'Dead cluster'
                                              : 'Coverage cluster')
                                        : (showCoverageTitle
                                              ? 'Coverage Zone'
                                              : 'Dead Zone'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (cluster != null) ...<Widget>[
                                    const SizedBox(height: 4),
                                    Text('Cells: ${cluster.childCount}'),
                                    Text(
                                      formatCoverageFraction(
                                        heard: cluster.coveredCount,
                                        filteredChildren: cluster.childCount,
                                      ),
                                    ),
                                    Text(
                                      coverageFractionMeaning,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Best cell',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  if (latest == null && latestRaw == null)
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _hexDetailLoading
                                              ? 'Loading scan details…'
                                              : 'Last Scan: unavailable',
                                        ),
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.location_on,
                                              size: 14,
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: _mapPopupDetailText(
                                                _zoneLocationLabel(
                                                  _selectedZone!,
                                                ),
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodyMedium,
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
                                              child: _mapPopupDetailText(
                                                _stripPopupEntityLabel(
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
                                              child: _mapPopupDetailText(
                                                popupNodeLabel,
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
                                              child: _mapPopupDetailText(
                                                _zoneLocationLabel(
                                                  _selectedZone!,
                                                ),
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodyMedium,
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
                                            'Scans: ${_hexDetailLoaded ? _hexDetailScans.length : (_selectedZone!.scanCount > 0 ? _selectedZone!.scanCount : _hexDetailScans.length)}',
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
                                          child: _mapPopupDetailText(
                                            _stripPopupEntityLabel(
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
                                          child: _mapPopupDetailText(
                                            popupNodeLabel,
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
                                          child: _mapPopupDetailText(
                                            _formatAltitude(
                                              latest.altitude,
                                              widget.unitSystem,
                                            ),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
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
                                          child: _mapPopupDetailText(
                                            _selectedZone!.id,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (showCoverageTitle)
                                      const Divider(height: 8, thickness: 0.6),
                                    if (showCoverageTitle)
                                      Text(
                                        'Scans: ${_hexDetailLoaded ? _hexDetailScans.length : (_selectedZone!.scanCount > 0 ? _selectedZone!.scanCount : _hexDetailScans.length)}',
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
                              painter: const PopupVPointerPainter(),
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
    if (coverageZoneIdMatchesPoint(zone.id, scan.latitude, scan.longitude)) {
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

    final selectedList = <_NodeFilterOption>[];
    final unselectedList = <_NodeFilterOption>[];
    for (final option in filtered) {
      if (_selected.contains(option.nodeId)) {
        selectedList.add(option);
      } else {
        unselectedList.add(option);
      }
    }
    final ordered = [...selectedList, ...unselectedList];

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
    if (coverageZoneIdMatchesPoint(zone.id, scan.latitude, scan.longitude)) {
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

String _zoneLocationLabel(CoverageZone zone) {
  if (parseHexDetailId(zone.id) == null) return zone.id;
  return '${zone.centerLat.toStringAsFixed(5)}, ${zone.centerLng.toStringAsFixed(5)}';
}

RawScan? _latestRawScanForZone(
  CoverageZone zone,
  List<RawScan> scans, {
  Set<String> nodeIdFilters = const <String>{},
}) {
  final zoneIdCenter = _parseHexKey(zone.id);
  final tileCell = parseHexDetailId(zone.id);
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
    if (tileCell != null) {
      final c = hexCellAt(scan.latitude, scan.longitude);
      matches = c.row == tileCell.row && c.col == tileCell.col;
    } else if (zone.id == scanHex) {
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
  return _formatNodeDisplayWithId(
    titleNameForNode(
      nodeId: nodeId,
      contactName: resolvedName,
      advertisedName: senderName,
    ),
    nodeId,
  );
}

String _formatNodeDisplayWithId(String label, String nodeId) {
  final trimmedLabel = label.trim();
  final shortId = _nodeFilterKey(nodeId);
  if (shortId.isEmpty) return trimmedLabel;
  if (trimmedLabel.isEmpty) return shortId;
  final alreadyTagged = RegExp(
    '\\(${RegExp.escape(shortId)}\\)\$',
    caseSensitive: false,
  ).hasMatch(trimmedLabel);
  if (alreadyTagged) return trimmedLabel;
  if (_looksLikeObserverId(trimmedLabel) &&
      _nodeFilterKey(trimmedLabel) == shortId) {
    return shortId;
  }
  return '$trimmedLabel ($shortId)';
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

/// Node filter keys for the heard nodes the hex index lists in [zones],
/// limited to [nodeFilters] when any are set.
Set<String> scopedNodeKeysFromZones(
  Iterable<CoverageZone> zones,
  Set<String> nodeFilters,
) {
  final out = <String>{};
  for (final zone in zones) {
    for (final id in zone.nodeIds) {
      // Index zones already carry 8-digit keys (no RegExp per pan frame).
      final key = _isNodeKey(id) ? id : _nodeFilterKey(id);
      if (key.isEmpty) continue;
      if (nodeFilters.isNotEmpty && !nodeFilters.contains(key)) continue;
      out.add(key);
    }
  }
  return out;
}

/// The dataset is rebuilt about once a second (location fixes, zone list
/// copies) while the cells stay the same objects. Reuse the last key set
/// when every cell is identical and the filters match.
class _ScopedNodeKeysMemo {
  List<CoverageZone>? _zones;
  Set<String> _filters = const <String>{};
  Set<String> _keys = const <String>{};

  Set<String> keysFor(List<CoverageZone> zones, Set<String> filters) {
    final last = _zones;
    if (last != null &&
        last.length == zones.length &&
        _filters.length == filters.length &&
        _filters.containsAll(filters)) {
      var same = true;
      for (var i = 0; i < zones.length; i++) {
        if (!identical(last[i], zones[i])) {
          same = false;
          break;
        }
      }
      if (same) return _keys;
    }
    _zones = zones;
    _filters = Set<String>.of(filters);
    _keys = scopedNodeKeysFromZones(zones, filters);
    return _keys;
  }
}

bool _isNodeKey(String id) {
  if (id.length != 8) return false;
  for (final c in id.codeUnits) {
    final ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 70);
    if (!ok) return false;
  }
  return true;
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
  return resolvedNameForNodeId(resolvedNodeNames, nodeId) ?? '';
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

/// Hex-popup detail line. One point smaller than [style], never under 11,
/// wrapping to three lines so long names stay on a 360dp phone.
Text _mapPopupDetailText(
  String text, {
  TextStyle? style,
  TextAlign? textAlign,
}) {
  final base = style ?? const TextStyle(fontSize: 14);
  final current = base.fontSize ?? 14;
  final reduced = current - 1;
  final fontSize = reduced < 11 ? 11.0 : reduced;
  return Text(
    text,
    softWrap: true,
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    textAlign: textAlign,
    style: base.copyWith(fontSize: fontSize),
  );
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
      return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    case BaseLayer.standard:
      return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    case BaseLayer.satellite:
      return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  }
}

BaseLayer _defaultBaseLayerForBrightness(Brightness brightness) {
  return brightness == Brightness.dark ? BaseLayer.dark : BaseLayer.standard;
}

/// Dead-zone hex outline and legend swatch on the map. Gray, because red
/// already means Poor coverage.
const Color deadZoneMapColor = Color(0xFF9CA3AF);

/// Map backdrop under the dark basemap while tiles load.
const Color darkBasemapBackground = Color(0xFF1C1C1E);

/// Highest zoom the basemap tile servers serve (OSM standard and dark).
const double basemapMaxNativeZoom = 19;

/// Deepest zoom the map allows. Above [basemapMaxNativeZoom] the basemap
/// shows scaled-up native tiles.
const double mapMaxZoom = 21;

/// Clamps an automatic camera fit or focus zoom (hex tap, node focus, node
/// filter) so it never goes past the basemap's native tiles. Manual pinch
/// zoom is not limited by this.
double capFocusZoom(double zoom) {
  if (!zoom.isFinite) return basemapMaxNativeZoom;
  return zoom > basemapMaxNativeZoom ? basemapMaxNativeZoom : zoom;
}

/// Invert + 180° hue rotate, identical to flutter_map's darkModeTileBuilder.
const ColorFilter darkBasemapTileFilter = ColorFilter.matrix(<double>[
  0.5740000009536743,
  -1.4299999475479126,
  -0.14399999380111694,
  0,
  255,
  -0.4259999990463257,
  -0.429999977350235,
  -0.14399999380111694,
  0,
  255,
  -0.4259999990463257,
  -1.4299999475479126,
  0.8559999465942383,
  0,
  255,
  0,
  0,
  0,
  1,
  0,
]);

class _BatchHexMemo {
  const _BatchHexMemo(this.draw, this.hex);

  final MapDrawPolygon draw;
  final CoverageBatchHex hex;

  bool matches(MapDrawPolygon other) =>
      identical(draw.points, other.points) &&
      draw.isDeadZone == other.isDeadZone &&
      draw.avgRssi == other.avgRssi &&
      draw.avgSnr == other.avgSnr;
}

List<CoverageBatchHex> _batchHexesForDraw(
  List<MapDrawPolygon> drawn,
  Map<String, _BatchHexMemo> memo,
) {
  final hexes = <CoverageBatchHex>[];
  for (final draw in drawn) {
    if (draw.points.length < 3) continue;
    final cached = memo[draw.hitZoneId];
    if (cached != null && cached.matches(draw)) {
      hexes.add(cached.hex);
      continue;
    }
    final hex = _batchHexForDraw(draw);
    memo[draw.hitZoneId] = _BatchHexMemo(draw, hex);
    hexes.add(hex);
  }
  return hexes;
}

CoverageBatchHex _batchHexForDraw(MapDrawPolygon draw) {
  var lat = 0.0;
  var lng = 0.0;
  for (final point in draw.points) {
    lat += point.latitude;
    lng += point.longitude;
  }
  final center = LatLng(lat / draw.points.length, lng / draw.points.length);
  if (draw.isDeadZone) {
    // Dead Zone only when nothing was heard: solid gray 1 px border (same
    // width as every other hex) over a very faint gray fill.
    return CoverageBatchHex(
      points: draw.points,
      hitId: draw.hitZoneId,
      fill: deadZoneMapColor.withValues(alpha: legendDeadZoneFillOpacity),
      border: deadZoneMapColor,
      center: center,
    );
  }
  // Weak-but-heard cells use Poor/Noisy/etc. via RSSI/SNR classification.
  final color = signalColorForValues(
    rssi: draw.avgRssi,
    snr: draw.avgSnr,
    includeDeadZone: false,
  );
  return CoverageBatchHex(
    points: draw.points,
    hitId: draw.hitZoneId,
    fill: color.withValues(alpha: legendSignalFillOpacity),
    border: color,
    center: center,
  );
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
    final d = distanceMiles(observerLat, observerLng, z.centerLat, z.centerLng);
    return d <= radiusMiles;
  }).toList();
}

class _MapDataset {
  const _MapDataset({
    required this.zones,
    required this.scans,
    required this.radius,
    required this.lat,
    required this.lng,
    required this.focusNodeId,
    required this.selectedCount,
    required this.filterHash,
    required this.filtered,
    required this.identity,
    required this.scopedNodes,
    required this.active,
    required this.dead,
    required this.avgRssi,
    required this.avgSnr,
  });

  final List<CoverageZone> zones;
  final List<ScanResult> scans;
  final int radius;
  final double? lat;
  final double? lng;
  final String? focusNodeId;
  final int selectedCount;
  final int filterHash;
  final List<CoverageZone> filtered;
  final int identity;
  final int scopedNodes;
  final int active;
  final int dead;
  final double avgRssi;
  final double avgSnr;
}
